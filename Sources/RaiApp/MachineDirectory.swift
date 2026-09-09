import Combine
import Foundation
import RaiCore

/// Owns metadata transports. Terminal views create separate endpoint connections.
@MainActor
final class MachineDirectory: ObservableObject {
    static let shared = MachineDirectory()
    @Published private(set) var state = MachineDirectoryState()
    private var connections: [MachineEndpoint: HerdrEndpointConnection] = [:]
    private var tunnels: [MachineEndpoint: RemoteConnection] = [:]
    private var tasks: [MachineEndpoint: Task<Void, Never>] = [:]
    private var paths: [MachineEndpoint: String] = [:]
    private var saved: [SavedMachine] = []
    private var setupProcess: MachineSetupProcess?
    private var stopped = false
    private var notificationTracker = MachineNotificationTracker()
    var notificationHandler: ((MachineNotificationChanges) -> Void)?
    private var acceptedRequests: Set<UUID> = []
    private let run: ([String]) async throws -> Data

    init(run: @escaping ([String]) async throws -> Data = MachineCommandRunner.run) { self.run = run }

    func stop() {
        stopped = true
        setupProcess?.cancel()
        setupProcess = nil
        for endpoint in Array(tasks.keys) { disconnect(endpoint) }
    }

    func resolve(_ endpoint: MachineEndpoint, connectionID: String) -> String? {
        guard let entry = state.entry(for: endpoint), entry.health == .online,
              entry.connectionID == connectionID else { return nil }
        return paths[endpoint]
    }

    func accepts(_ identity: EndpointViewIdentity) -> Bool {
        guard let endpoint = identity.machineEndpoint else { return false }
        return resolve(endpoint, connectionID: identity.connectionID) != nil
    }

    /// Only a current saved endpoint can produce a remote foreground CLI invocation.
    func sshCommand(endpoint: MachineEndpoint, connectionID: String, arguments: [String]) throws -> [String] {
        guard resolve(endpoint, connectionID: connectionID) != nil,
              let machine = saved.first(where: { $0.endpoint == endpoint && $0.enabled }) else {
            throw HerdrEndpointError.staleIdentity
        }
        return try RemoteConnection.foregroundArguments(target: machine.target, sessionName: endpoint.session, arguments: arguments)
    }

    func perform(_ request: MachineRequest) async {
        guard !stopped else { state.error = "The machine directory stopped."; return }
        if case .answerSetup(let id, let promptID, let approve) = request.operation {
            guard state.setup?.id == id, let setupProcess else { state.error = "This setup request is stale."; return }
            do { try setupProcess.answer(promptID: promptID, approve: approve) }
            catch { state.error = error.localizedDescription }
            return
        }
        if case .cancelSetup(let id) = request.operation {
            guard state.setup?.id == id else { state.error = "This setup request is stale."; return }
            setupProcess?.cancel()
            return
        }
        guard !state.busy, !acceptedRequests.contains(request.id) else { return }
        if request.operation != .refresh, request.revision != state.revision {
            state.error = "The machine list changed. Review the machines again."
            return
        }
        // Connection identity and catalog revision prevent reusing old requests.
        guard acceptedRequests.count < 4096 else {
            state.error = "Restart the Mac app before sending more machine operations."
            return
        }
        acceptedRequests.insert(request.id)
        state.busy = true; state.error = nil
        defer { state.busy = setupProcess != nil }
        do {
            if case .reconnect(let endpoint) = request.operation {
                guard state.entry(for: endpoint)?.health != .disabled else {
                    throw MachineCatalogError.invalid("Enable this machine before connecting.")
                }
                reconnect(endpoint)
            } else {
                if case .add(let target, _, _) = request.operation {
                    if let fixture = try LabSSHConfiguration.load(root: AppDataPaths.current.isolatedRoot) { try fixture.validate(target: target) }
                    try startSetup(request)
                    return
                }
                if request.operation != .refresh { _ = try await run(request.operation.arguments()) }
                try await refresh()
            }
        } catch { state.error = error.localizedDescription }
    }

    private func startSetup(_ request: MachineRequest) throws {
        guard case .add(let target, let label, let session) = request.operation,
              let binary = HerdrCLI.resolvedBinaryPath else {
            throw MachineCatalogError.invalid("Install Herdr before adding a machine.")
        }
        let arguments = try request.operation.arguments()
        state.setup = .init(id: request.id, target: target, label: label, session: session)
        let setup = MachineSetupProcess { [weak self] output, promptID in
            guard self?.state.setup?.id == request.id else { return }
            self?.state.setup?.output = output
            self?.state.setup?.promptID = promptID
        } finish: { [weak self] status in
            guard let self, state.setup?.id == request.id else { return }
            setupProcess = nil
            state.setup?.finished = true; state.setup?.promptID = nil
            guard !stopped else { state.busy = false; return }
            if status != 0 { state.error = status == -1 ? "Machine setup was canceled." : "Machine setup failed. Read the setup output." }
            Task {
                defer { self.state.busy = false }
                do { try await self.refresh() }
                catch { self.state.error = error.localizedDescription }
            }
        }
        var environment = ProcessInfo.processInfo.environment
        if let fixture = try LabSSHConfiguration.load(root: AppDataPaths.current.isolatedRoot) {
            environment["PATH"] = fixture.wrapperDirectory + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        }
        setupProcess = setup
        do { try setup.start(binary: binary, arguments: arguments, environment: environment) }
        catch { setupProcess = nil; state.setup?.finished = true; throw error }
    }

    func refresh() async throws {
        let machines = try MachineCatalog.parse(await run(["machine", "list", "--json"]))
        let sessions = try SessionListParser.parse(String(decoding: await run(["session", "list", "--json"]), as: UTF8.self))
        guard !stopped else { throw CancellationError() }
        var entries = sessions.map { session in
            let endpoint = MachineEndpoint(session: session.name)
            paths[endpoint] = session.socketPath
            return MachineEntry(endpoint: endpoint, label: "This Mac · " + session.name,
                health: session.isRunning ? .disconnected : .disabled)
        }
        entries += machines.map { MachineEntry(endpoint: $0.endpoint, label: $0.label, health: $0.enabled ? .disconnected : .disabled, target: $0.target) }
        let retained = Set(entries.filter { $0.health != .disabled }.map(\.endpoint))
        for endpoint in Array(tasks.keys) where !retained.contains(endpoint) { disconnect(endpoint) }
        for machine in machines {
            if let previous = saved.first(where: { $0.id == machine.id }), previous.target != machine.target || previous.session != machine.session {
                disconnect(previous.endpoint)
            }
        }
        saved = machines
        for index in entries.indices {
            let endpoint = entries[index].endpoint
            if entries[index].health != .disabled, tasks[endpoint] != nil, var existing = state.entry(for: endpoint) {
                existing.label = entries[index].label
                existing.target = entries[index].target
                entries[index] = existing
            }
        }
        state.entries = entries; state.revision = UUID()
        for entry in entries where entry.health != .disabled && tasks[entry.endpoint] == nil { connect(entry.endpoint) }
    }

    private func reconnect(_ endpoint: MachineEndpoint) {
        guard state.entry(for: endpoint) != nil else { return }
        disconnect(endpoint)
        connect(endpoint)
    }

    private func retireNotifications(_ endpoint: MachineEndpoint) {
        let changes = notificationTracker.disconnect(endpoint)
        if !changes.retiredIDs.isEmpty { notificationHandler?(changes) }
    }

    private func disconnect(_ endpoint: MachineEndpoint) {
        retireNotifications(endpoint)
        tasks.removeValue(forKey: endpoint)?.cancel()
        connections.removeValue(forKey: endpoint)?.disconnect()
        tunnels.removeValue(forKey: endpoint)?.stop()
        if endpoint.profileID != nil { paths.removeValue(forKey: endpoint) }
        update(endpoint) { $0.health = .disconnected; $0.connectionID = nil }
    }

    private func connect(_ endpoint: MachineEndpoint) {
        guard !stopped else { return }
        let generation = UUID().uuidString
        update(endpoint) { $0.connectionID = generation; $0.health = .connecting; $0.error = nil }
        tasks[endpoint] = Task { [weak self] in
            guard let self else { return }
            do {
                let socket = try await socketPath(for: endpoint)
                guard !Task.isCancelled, state.entry(for: endpoint)?.connectionID == generation else { return }
                let connection = HerdrEndpointConnection()
                connections[endpoint] = connection
                let snapshot = try await connection.connect(socketPath: RemoteConnection.clientSocketPath(for: socket))
                receive(snapshot, endpoint: endpoint, generation: generation)
                for try await snapshot in connection.snapshots {
                    guard !Task.isCancelled else { return }
                    receive(snapshot, endpoint: endpoint, generation: generation)
                }
                throw MachineCatalogError.invalid("The machine disconnected.")
            } catch {
                guard !Task.isCancelled, state.entry(for: endpoint)?.connectionID == generation else { return }
                connections.removeValue(forKey: endpoint)?.disconnect()
                tunnels.removeValue(forKey: endpoint)?.stop()
                tasks.removeValue(forKey: endpoint)
                update(endpoint) { $0.health = .disconnected; $0.connectionID = nil; $0.error = error.localizedDescription }
                retireNotifications(endpoint)
                tasks[endpoint] = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(10))
                    guard !Task.isCancelled, let self,
                          state.entry(for: endpoint)?.health == .disconnected else { return }
                    connect(endpoint)
                }
            }
        }
    }

    private func socketPath(for endpoint: MachineEndpoint) async throws -> String {
        guard let profileID = endpoint.profileID else {
            guard let path = paths[endpoint] else { throw HerdrEndpointError.staleIdentity }
            try LabLaunch.requireContainedPath(path, root: AppDataPaths.current.isolatedRoot)
            return path
        }
        guard let machine = saved.first(where: { $0.id == profileID && $0.endpoint == endpoint && $0.enabled }) else {
            throw HerdrEndpointError.staleIdentity
        }
        // Discovery never invokes `machine add`, installation, or server launch.
        let remote = try await RemoteConnection.discoverSocket(target: machine.target, sessionName: machine.session)
        try Task.checkCancellation()
        let tunnel = RemoteConnection(target: remote.target, sessionName: remote.sessionName, remoteSocketPath: remote.socketPath)
        tunnels[endpoint] = tunnel
        try await tunnel.start()
        try Task.checkCancellation()
        paths[endpoint] = tunnel.localSocketPath
        return tunnel.localSocketPath
    }

    private func receive(_ snapshot: HerdrEndpointSnapshot, endpoint: MachineEndpoint, generation: String) {
        guard state.entry(for: endpoint)?.connectionID == generation else { return }
        let agents = snapshot.agents.compactMap { value -> MachineAgent? in
            guard let row = value.objectValue, let paneID = row["pane_id"]?.stringValue else { return nil }
            return MachineAgent(resource: .init(endpoint: endpoint, connectionID: generation, bootID: snapshot.bootID, paneID: paneID),
                name: row["name"]?.stringValue ?? row["title"]?.stringValue ?? paneID,
                agent: row["agent"]?.stringValue ?? "", status: row["agent_status"]?.stringValue ?? "unknown")
        }
        update(endpoint) { $0.health = .online; $0.agents = agents; $0.error = nil }
        if let entry = state.entry(for: endpoint) {
            let changes = notificationTracker.receive(snapshot, entry: entry)
            if !changes.notices.isEmpty || !changes.retiredIDs.isEmpty { notificationHandler?(changes) }
        }
    }

    private func update(_ endpoint: MachineEndpoint, _ change: (inout MachineEntry) -> Void) {
        guard let index = state.entries.firstIndex(where: { $0.endpoint == endpoint }) else { return }
        change(&state.entries[index])
    }
}
