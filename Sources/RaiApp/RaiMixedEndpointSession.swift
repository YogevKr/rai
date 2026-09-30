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
    private var terminalIDs: [String: String] = [:]
    private var hasTerminalIDSnapshot = false
    private let metadataClient: HerdrClient
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
        sharedTerminalPool: TerminalPool? = nil,
        projectionModel: RaiMixedViewModel? = nil
    ) {
        self.endpoint = endpoint
        self.projectionModel = projectionModel
        ownsPool = sharedTerminalPool == nil
        configuredAttachExecutable = attachExecutable
        metadataClient = HerdrClient(socketPath: socketPath)
        model = EndpointWindowModel(
            socketPath: socketPath,
            machineEndpoint: endpoint,
            machineConnectionID: connectionID
        )
        pool = sharedTerminalPool ?? TerminalPool(
            socketPath: socketPath,
            attachExecutable: attachExecutable,
            requiresRuntimeExecutable: true
        )
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
        terminalIDTask = Task { [weak self] in
            do {
                let info = try await client.serverInfo()
                let executable = try await Self.attachExecutable(
                    for: info.protocol, localExecutable: configuredAttachExecutable ?? HerdrCLI.resolvedBinaryPath
                )
                try Task.checkCancellation()
                self?.pool.runtimeExecutable = executable
                self?.prepared = true
                while !Task.isCancelled {
                    let raw = try await client.snapshot()
                    try Task.checkCancellation()
                    self?.mergeTerminalIDs(from: raw)
                    try await Task.sleep(for: .seconds(1))
                }
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
                                 archive: HerdrClientArchive = HerdrClientArchive()) async throws -> String {
        if let archived = archive.executable(for: protocolVersion) {
            return archived.path
        }
        guard let local = localExecutable,
              let result = try? await MachineCommandRunner.capture(
                  binary: local, arguments: ["api", "schema", "--json"], timeout: 30
              ), result.status == 0,
              let schema = try? JSONSerialization.jsonObject(with: result.standardOutput) as? [String: Any],
              let localProtocol = schema["protocol"] as? Int,
              localProtocol == protocolVersion else {
            throw HerdrEndpointError.incompatible(
                "Install a Herdr client that matches this server (protocol \(protocolVersion)), then reconnect."
            )
        }
        return local
    }

    func focus(paneID: String) {
        model.select(paneID: paneID)
    }

    func pane(paneID: String) -> JSONValue? {
        snapshot?.panes.first { $0.objectValue?["pane_id"]?.stringValue == paneID }
    }

    private func receive(_ next: HerdrEndpointSnapshot?) {
        guard !stopped, let next else { return }
        let merged = Self.withTerminalIDs(next, terminalIDs: terminalIDs) ?? next
        snapshot = merged
        if hasTerminalIDSnapshot {
            pool.retain(terminalIDs: Set(terminalIDs.values))
        }
        guard prepared, let connectionID else { return }
        projectionModel?.receive(endpoint: endpoint, connectionID: connectionID, snapshot: merged)
    }

    private func mergeTerminalIDs(from raw: SessionSnapshot) {
        terminalIDs = Dictionary(uniqueKeysWithValues: raw.panes.map { ($0.paneID, $0.terminalID) })
        hasTerminalIDSnapshot = true
        receive(snapshot)
    }

    private static func withTerminalIDs(
        _ snapshot: HerdrEndpointSnapshot,
        terminalIDs: [String: String]
    ) -> HerdrEndpointSnapshot? {
        guard !terminalIDs.isEmpty,
              let data = try? JSONEncoder().encode(snapshot),
              var root = try? JSONDecoder().decode([String: JSONValue].self, from: data),
              case .array(var panes)? = root["panes"] else { return nil }
        for index in panes.indices {
            guard case .object(var pane) = panes[index],
                  let paneID = pane["pane_id"]?.stringValue,
                  let terminalID = terminalIDs[paneID] else { continue }
            pane["terminal_id"] = .string(terminalID)
            panes[index] = .object(pane)
        }
        root["panes"] = .array(panes)
        guard let merged = try? JSONEncoder().encode(root) else { return nil }
        return try? JSONDecoder().decode(HerdrEndpointSnapshot.self, from: merged)
    }
}
