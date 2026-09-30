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

    private var snapshotObservation: AnyCancellable?
    private var errorObservation: AnyCancellable?
    private var terminalIDTask: Task<Void, Never>?
    private var terminalIDs: [String: String] = [:]
    private var hasTerminalIDSnapshot = false
    private let metadataClient: HerdrClient
    private weak var projectionModel: RaiMixedViewModel?

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
        metadataClient = HerdrClient(socketPath: socketPath)
        model = EndpointWindowModel(
            socketPath: socketPath,
            machineEndpoint: endpoint,
            machineConnectionID: connectionID
        )
        pool = sharedTerminalPool ?? TerminalPool(socketPath: socketPath, attachExecutable: attachExecutable)
        snapshot = model.snapshot
        snapshotObservation = model.$snapshot.sink { [weak self] snapshot in
            self?.receive(snapshot)
        }
        errorObservation = model.$error.sink { [weak self] error in
            guard error != nil, let self else { return }
            self.snapshot = nil
            self.projectionModel?.disconnect(endpoint: self.endpoint)
        }
    }

    deinit {
        terminalIDTask?.cancel()
        metadataClient.disconnect()
    }

    var connectionID: String? { model.machineConnectionID }
    var apiSocketPath: String { model.apiSocketPath }
    var hasError: Bool { model.error != nil }

    func start() {
        model.start()
        terminalIDTask?.cancel()
        let client = metadataClient
        terminalIDTask = Task { [weak self] in
            if let info = try? await client.serverInfo(),
               let executable = HerdrClientArchive().executable(for: info.protocol) {
                await MainActor.run { self?.pool.runtimeExecutable = executable.path }
            }
            while !Task.isCancelled {
                if let raw = try? await client.snapshot() {
                    await MainActor.run { self?.mergeTerminalIDs(from: raw) }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        terminalIDTask?.cancel()
        terminalIDTask = nil
        metadataClient.disconnect()
        model.stop()
        snapshot = nil
        terminalIDs = [:]
        hasTerminalIDSnapshot = false
        projectionModel?.disconnect(endpoint: endpoint)
    }

    func focus(paneID: String) {
        model.select(paneID: paneID)
    }

    func pane(paneID: String) -> JSONValue? {
        snapshot?.panes.first { $0.objectValue?["pane_id"]?.stringValue == paneID }
    }

    private func receive(_ next: HerdrEndpointSnapshot?) {
        guard let next else { return }
        let merged = Self.withTerminalIDs(next, terminalIDs: terminalIDs) ?? next
        snapshot = merged
        if hasTerminalIDSnapshot {
            pool.retain(terminalIDs: Set(terminalIDs.values))
        }
        guard let connectionID else { return }
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
