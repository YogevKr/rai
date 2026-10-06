import Combine
import Foundation
import RaiCore

/// One endpoint connection and one direct terminal pool used by a mixed view.
@MainActor
final class RaiMixedEndpointSession: ObservableObject {
    let endpoint: MachineEndpoint
    let model: EndpointWindowModel
    let pool: TerminalPool
    @Published private(set) var snapshot: HerdrEndpointSnapshot?
    @Published private(set) var error: String?

    private var snapshotObservation: AnyCancellable?
    private var errorObservation: AnyCancellable?
    private var terminalIDTask: Task<Void, Never>?
    private var terminalIDRefreshTask: Task<Void, Never>?
    private var terminalIDs: [String: String] = [:]
    private var hasTerminalIDSnapshot = false
    private let metadataClient: HerdrClient
    private let socketPath: String
    private weak var projectionModel: RaiMixedViewModel?
    private let ownsPool: Bool
    private let configuredAttachExecutable: String?
    private var prepared = false
    private var stopped = false

    init(
        endpoint: MachineEndpoint,
        connectionID: String,
        socketPath: String,
        attachExecutable: String? = nil,
        target: String? = nil,
        sharedTerminalPool: TerminalPool? = nil,
        projectionModel: RaiMixedViewModel? = nil
    ) {
        self.endpoint = endpoint
        self.projectionModel = projectionModel
        ownsPool = sharedTerminalPool == nil
        configuredAttachExecutable = attachExecutable
        self.socketPath = socketPath
        metadataClient = HerdrClient(socketPath: socketPath)
        model = EndpointWindowModel(
            socketPath: socketPath,
            machineEndpoint: endpoint,
            machineConnectionID: connectionID
        )
        pool = sharedTerminalPool ?? TerminalPool(
            socketPath: socketPath,
            attachExecutable: attachExecutable,
            requiresRuntimeExecutable: true,
            // A remote Herdr client may already own a Codex terminal. A Rai
            // view must not displace that client when it first renders.
            redrawOnAttach: true,
            takeoverOnAttach: target == nil
        )
        pool.predictiveEchoHerdLocation = target == nil ? .local : .remote
        snapshot = model.snapshot
        snapshotObservation = model.$snapshot.sink { [weak self] snapshot in
            self?.receive(snapshot)
        }
        errorObservation = model.$error.sink { [weak self] error in
            guard error != nil, let self else { return }
            self.error = error
            self.stop()
        }
    }

    deinit {
        terminalIDTask?.cancel()
        metadataClient.disconnect()
    }

    var connectionID: String? { model.machineConnectionID }
    var apiSocketPath: String { model.apiSocketPath }
    var hasError: Bool { error != nil }

    func start() {
        guard !stopped, terminalIDTask == nil else { return }
        model.start()
        let client = metadataClient
        let configuredAttachExecutable = configuredAttachExecutable
        let socketPath = socketPath
        terminalIDTask = Task { [weak self] in
            do {
                // The session snapshot contains both the client protocol and
                // every pane's terminal ID. Reuse it for startup instead of
                // paying for a separate ping and a second snapshot over SSH.
                let initialSnapshot = try await client.snapshot()
                let executable = try await Self.attachExecutable(
                    for: initialSnapshot.protocol,
                    localExecutable: configuredAttachExecutable ?? HerdrCLI.resolvedBinaryPath,
                    socketPath: socketPath
                )
                try Task.checkCancellation()
                self?.pool.runtimeExecutable = executable
                self?.prepared = true
                self?.mergeTerminalIDs(from: initialSnapshot)
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.error = error.localizedDescription
                self.stop()
            }
        }
    }

    func stop() {
        stopped = true
        prepared = false
        terminalIDTask?.cancel()
        terminalIDTask = nil
        terminalIDRefreshTask?.cancel()
        terminalIDRefreshTask = nil
        metadataClient.disconnect()
        model.stop()
        // Late SwiftUI updates cannot recreate clients after this session ends.
        if ownsPool { pool.retain(terminalIDs: []) }
        snapshot = nil
        terminalIDs = [:]
        hasTerminalIDSnapshot = false
        projectionModel?.disconnect(endpoint: endpoint)
    }

    static func attachExecutable(for protocolVersion: Int, localExecutable: String?,
                                 socketPath: String? = nil,
                                 archive: HerdrClientArchive = HerdrClientArchive()) async throws -> String {
        if let archived = archive.executable(for: protocolVersion) {
            return archived.path
        }
        var environment = ProcessInfo.processInfo.environment
        if let socketPath { environment["HERDR_SOCKET_PATH"] = socketPath }
        guard let local = localExecutable,
              let localProtocol = await Self.probeProtocol(
                  executable: local,
                  environment: environment
              ),
              localProtocol == protocolVersion else {
            throw HerdrEndpointError.incompatible(
                "Install a Herdr client that matches this server (protocol \(protocolVersion)), then reconnect."
            )
        }
        return local
    }

    private static func probeProtocol(
        executable: String,
        environment: [String: String]
    ) async -> Int? {
        let schemaURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rai-herdr-schema-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: schemaURL) }

        if let result = try? await MachineCommandRunner.capture(
            binary: executable,
            arguments: ["api", "schema", "--output", schemaURL.path],
            timeout: 30,
            environment: environment
        ), result.status == 0,
           let data = try? Data(contentsOf: schemaURL),
           let schema = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let localProtocol = schema["protocol"] as? Int {
            return localProtocol
        }

        // Small test clients and older Herdr builds print the schema to stdout.
        // Keep this fallback after --output so full schemas never hit capture's size limit.
        guard let result = try? await MachineCommandRunner.capture(
            binary: executable,
            arguments: ["api", "schema", "--json"],
            timeout: 30,
            environment: environment
        ), result.status == 0,
        let schema = try? JSONSerialization.jsonObject(with: result.standardOutput) as? [String: Any] else {
            return nil
        }
        return schema["protocol"] as? Int
    }

    func focus(paneID: String) {
        model.select(paneID: paneID)
    }

    func pane(paneID: String) -> JSONValue? {
        snapshot?.panes.first { $0.objectValue?["pane_id"]?.stringValue == paneID }
    }

    private func receive(_ next: HerdrEndpointSnapshot?) {
        guard !stopped, let next else { return }
        snapshot = next
        if hasTerminalIDSnapshot {
            pool.retain(terminalIDs: Set(terminalIDs.values))
        }
        guard prepared, let connectionID else { return }
        if Self.needsTerminalIDRefresh(next, terminalIDs: terminalIDs, hasSnapshot: hasTerminalIDSnapshot) {
            refreshTerminalIDs()
        }
        projectionModel?.receive(
            endpoint: endpoint,
            connectionID: connectionID,
            snapshot: next,
            terminalIDs: terminalIDs
        )
    }

    /// The endpoint stream already reports metadata revisions. Refresh terminal
    /// IDs after a revision change instead of polling every endpoint each second.
    private func refreshTerminalIDs() {
        guard !stopped, prepared, terminalIDRefreshTask == nil else { return }
        let client = metadataClient
        terminalIDRefreshTask = Task { [weak self] in
            do {
                let raw = try await client.snapshot()
                try Task.checkCancellation()
                self?.mergeTerminalIDs(from: raw)
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.error = error.localizedDescription
                self.stop()
            }
            guard let self, !self.stopped else { return }
            self.terminalIDRefreshTask = nil
            if let snapshot = self.snapshot,
               Self.needsTerminalIDRefresh(snapshot, terminalIDs: self.terminalIDs,
                                            hasSnapshot: self.hasTerminalIDSnapshot) {
                self.refreshTerminalIDs()
            }
        }
    }

    static func needsTerminalIDRefresh(
        _ snapshot: HerdrEndpointSnapshot,
        terminalIDs: [String: String],
        hasSnapshot: Bool
    ) -> Bool {
        guard hasSnapshot else { return true }
        let paneIDs = Set(snapshot.panes.compactMap {
            $0.objectValue?["pane_id"]?.stringValue
        })
        // The endpoint view can contain one tab while the API snapshot contains
        // every tab. Refresh only when a visible pane lacks a terminal mapping.
        return !paneIDs.isSubset(of: Set(terminalIDs.keys))
    }

    private func mergeTerminalIDs(from raw: SessionSnapshot) {
        terminalIDs = Dictionary(uniqueKeysWithValues: raw.panes.map { ($0.paneID, $0.terminalID) })
        hasTerminalIDSnapshot = true
        receive(snapshot)
    }

}
