import Combine
import Foundation
import RaiCore

@MainActor
final class EndpointWindowModel: ObservableObject {
    @Published private(set) var snapshot: HerdrEndpointSnapshot?
    @Published private(set) var surface: HerdrEndpointSurface?
    @Published private(set) var error: String?
    @Published private(set) var terminalResult: EndpointTextResult?
    private var textClient: HerdrPinnedRPC?
    @Published private(set) var layoutResult: EndpointLayoutResult?
    private var layoutClient: HerdrPinnedRPC?
    @Published private(set) var worktreeResult: EndpointWorktreeResult?
    @Published private(set) var busy = false
    @Published private(set) var methods: Set<String> = []
    @Published private(set) var pluginResult: EndpointPluginResult?
    private var pluginClient: HerdrPinnedRPC?
    private var pluginRequestID: UUID?
    private var localPluginReviewID: UUID?
    private let installPlugin: (EndpointPluginOperation, String, String) async throws -> JSONValue
    private let dataPaths: AppDataPaths
    private var remotePluginInstaller: EndpointRemotePluginInstaller?
    var apiSocketPath: String { socketPath }
    @Published private(set) var windowTitle: String?
    private var titleTask: Task<Void, Never>?
    @Published private(set) var notifications: [EndpointNotification] = []
    private var notificationTask: Task<Void, Never>?
    private var socketPath: String
    private var remoteContext: RemoteConnection.Context?
    private var remoteTunnel: RemoteConnection?
    var retainsHostConnection: Bool { remoteContext != nil }
    var usesRemoteHost: Bool { remoteContext != nil || machineEndpoint?.profileID != nil }
    private var endpoint: HerdrEndpointConnection?
    private var snapshotTask: Task<Void, Never>?
    private var surfaceTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var queuedInputBytes = 0
    private var queuedInputs = 0
    private struct InputLease: Equatable {
        let paneID: String
        let bootID: String
        let revision: UInt64
        let popupID: String?
        let epoch: UUID
    }
    private var pendingText: EndpointTextBatch<InputLease>?
    private var inputEpoch = UUID()
    private var size: (columns: UInt16, rows: UInt16)?
    @Published private(set) var generation = UUID()
    @Published private(set) var scrollActivity: [String: UInt64] = [:]
    private var scrollTargets: [String: UInt64] = [:]
    private var scrolling = false
    private var pendingMachineResource: MachineResource?
    private var selectedMachineEndpoint: MachineEndpoint?
    private(set) var machineConnectionID: String?
    var machineEndpoint: MachineEndpoint? { selectedMachineEndpoint }
    private var graphicsPolicy = EndpointGraphicsPolicy.unknown("Open a pane to read its settings.")
    private var graphicsPolicyTask: Task<Void, Never>?
    private var unfilteredSurface: HerdrEndpointSurface?
    @Published private(set) var agentLaunchResult: EndpointAgentLaunchResult?
    private var agentLaunchClient: HerdrPinnedRPC?
    @Published private(set) var graphicsPolicyWarning: String?

    init(socketPath: String, machineEndpoint: MachineEndpoint? = nil, machineConnectionID: String? = nil,
         remoteContext: RemoteConnection.Context? = nil,
         installPlugin: @escaping (EndpointPluginOperation, String, String) async throws -> JSONValue = {
             try await RaiApp.sharedModel.endpointPluginInstall($0, socketPath: $1, bootID: $2)
         }, dataPaths: AppDataPaths = .current) {
        self.installPlugin = installPlugin
        self.dataPaths = dataPaths
        self.socketPath = socketPath
        self.remoteContext = remoteContext
        self.selectedMachineEndpoint = machineEndpoint
        self.machineConnectionID = machineConnectionID
    }

    deinit {
        let tunnel = remoteTunnel
        Task { @MainActor in tunnel?.stop() }
        endpoint?.disconnect()
        layoutClient?.cancel()
        snapshotTask?.cancel(); surfaceTask?.cancel(); actionTask?.cancel(); resizeTask?.cancel()
        inputTask?.cancel()
        notificationTask?.cancel()
        titleTask?.cancel()
        graphicsPolicyTask?.cancel()
    }

    var acceptsInput: Bool {
        guard let snapshot, let surface else { return false }
        return error == nil && !busy && surface.bootID == snapshot.bootID
            && surface.projectionRevision <= snapshot.revision
            && surface.panes.first(where: \.focused)?.paneID == snapshot.focusedPaneID
    }

    func start() {
        guard endpoint == nil else { return }
        busy = true
        let endpoint = HerdrEndpointConnection()
        self.endpoint = endpoint
        let generation = generation
        snapshotTask = Task { [weak self] in
            do {
                guard let path = try await self?.prepareSocket(generation: generation) else { return }
                let first = try await endpoint.connect(socketPath: RemoteConnection.clientSocketPath(for: path))
                guard self?.generation == generation else { return }
                self?.snapshot = first
                let welcome = await endpoint.welcome
                guard self?.generation == generation else { return }
                self?.methods = Set(welcome?.methods ?? [])
                await self?.readGraphicsPolicy(snapshot: first, generation: generation)
                self?.watchGraphicsPolicy(generation: generation)
                guard self?.generation == generation else { return }
                let target = self?.pendingMachineResource
                if let target, target.bootID != first.bootID { throw HerdrEndpointError.staleIdentity }
                if let size = self?.size { try await endpoint.resize(columns: size.columns, rows: size.rows) }
                _ = try await endpoint.request(method: "client_shell.surface.set", params: ["active": .bool(true)], expectedBootID: first.bootID)
                guard self?.generation == generation else { return }
                if let target {
                    _ = try await endpoint.request(method: "pane.focus", params: ["pane_id": .string(target.paneID)], expectedBootID: target.bootID)
                    guard self?.generation == generation else { return }
                    self?.pendingMachineResource = nil
                }
                self?.busy = false
                for try await snapshot in endpoint.snapshots {
                    guard self?.generation == generation else { return }
                    self?.snapshot = snapshot
                }
            } catch { self?.record(error, generation: generation) }
        }
        titleTask = Task { [weak self] in
            do {
                for try await title in endpoint.windowTitles {
                    guard self?.generation == generation else { return }
                    self?.windowTitle = title
                }
            } catch { self?.record(error, generation: generation) }
        }
        notificationTask = Task { [weak self] in
            do {
                for try await notification in endpoint.notifications {
                    guard self?.generation == generation else { return }
                    self?.notifications.append(notification)
                    if let count = self?.notifications.count, count > 50 { self?.notifications.removeFirst(count - 50) }
                }
            } catch { self?.record(error, generation: generation) }
        }
        surfaceTask = Task { [weak self] in
            do {
                for try await surface in endpoint.surfaces {
                    guard self?.generation == generation else { return }
                    self?.unfilteredSurface = surface
                    self?.surface = self?.graphicsPolicy.apply(to: surface)
                }
            } catch { self?.record(error, generation: generation) }
        }
    }

    private func prepareSocket(generation: UUID) async throws -> String {
        guard self.generation == generation else { throw CancellationError() }
        guard let context = remoteContext else { return socketPath }
        let tunnel = RemoteConnection(target: context.target, sessionName: context.sessionName, remoteSocketPath: context.remoteSocketPath)
        remoteTunnel = tunnel
        tunnel.onUnexpectedExit = { [weak self] _, message in
            self?.record(RemoteConnectionError.tunnelFailed(message), generation: generation)
        }
        do {
            try await tunnel.start()
            guard self.generation == generation else { throw CancellationError() }
            socketPath = tunnel.localSocketPath
            return socketPath
        } catch {
            tunnel.stop()
            if remoteTunnel === tunnel { remoteTunnel = nil }
            throw error
        }
    }

    func stop() {
        remoteTunnel?.stop(); remoteTunnel = nil
        agentLaunchClient?.cancel(); agentLaunchClient = nil
        agentLaunchResult = nil
        if let id = localPluginReviewID {
            let installPlugin = installPlugin, path = socketPath, boot = snapshot?.bootID ?? ""
            Task { _ = try? await installPlugin(.cancelInstall(id), path, boot) }
        }
        localPluginReviewID = nil; pluginRequestID = nil
        remotePluginInstaller?.cancel()
        remotePluginInstaller = nil
        textClient?.cancel(); textClient = nil
        terminalResult = nil
        pluginClient?.cancel()
        pluginClient = nil
        pluginResult = nil
        notificationTask?.cancel()
        notificationTask = nil
        titleTask?.cancel(); titleTask = nil
        windowTitle = nil
        notifications = []
        worktreeResult = nil
        layoutResult = nil; layoutClient?.cancel(); layoutClient = nil
        generation = UUID()
        endpoint?.disconnect()
        endpoint = nil
        snapshotTask?.cancel(); surfaceTask?.cancel(); actionTask?.cancel(); resizeTask?.cancel()
        snapshotTask = nil; surfaceTask = nil; actionTask = nil; resizeTask = nil
        inputTask?.cancel()
        inputTask = nil
        queuedInputBytes = 0
        queuedInputs = 0
        pendingText = nil
        snapshot = nil
        surface = nil
        methods = []
        busy = false
        scrolling = false
        scrollTargets = [:]
        scrollActivity = [:]
        pendingMachineResource = nil
        graphicsPolicy = .unknown("Open a pane to read its settings.")
        graphicsPolicyTask?.cancel()
        graphicsPolicyTask = nil
        unfilteredSurface = nil
        graphicsPolicyWarning = nil
    }

    private func watchGraphicsPolicy(generation: UUID) {
        guard self.generation == generation else { return }
        graphicsPolicyTask?.cancel()
        graphicsPolicyTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, self.generation == generation, let snapshot = self.snapshot else { return }
                await self.readGraphicsPolicy(snapshot: snapshot, generation: generation)
            }
        }
    }

    private func readGraphicsPolicy(snapshot: HerdrEndpointSnapshot, generation: UUID) async {
        guard self.generation == generation else { return }
        guard let paneID = snapshot.focusedPaneID ?? snapshot.panes.first?.objectValue?["pane_id"]?.stringValue else {
            graphicsPolicyWarning = graphicsPolicy.warning
            return
        }
        let client = HerdrClient(socketPath: socketPath)
        defer { client.disconnect() }
        let policy: EndpointGraphicsPolicy
        do { policy = try await client.paneGraphicsEnabled(paneID: paneID) ? .enabled : .disabled }
        catch { policy = .unknown(error.localizedDescription) }
        guard self.generation == generation else { return }
        graphicsPolicy = policy
        graphicsPolicyWarning = policy.warning
        if let unfilteredSurface { self.surface = policy.apply(to: unfilteredSurface) }
    }

    func reconnect() {
        if let endpoint = selectedMachineEndpoint {
            guard let entry = MachineDirectory.shared.state.entry(for: endpoint) else {
                error = "The machine was removed. Select another machine."
                return
            }
            selectMachine(entry)
        } else { stop(); error = nil; start() }
    }

    func selectMachine(_ entry: MachineEntry, directory: MachineDirectory? = nil) {
        let directory = directory ?? .shared
        guard let connectionID = entry.connectionID,
              let path = directory.resolve(entry.endpoint, connectionID: connectionID) else {
            error = "The machine disconnected. Refresh the machine list."
            return
        }
        stop()
        remoteContext = nil
        socketPath = path
        selectedMachineEndpoint = entry.endpoint
        machineConnectionID = connectionID
        error = nil
        start()
    }

    func selectAgent(_ agent: MachineAgent, directory: MachineDirectory? = nil) {
        let directory = directory ?? .shared
        let target = agent.resource
        guard let entry = directory.state.entry(for: target.endpoint), entry.agents.contains(agent),
              let path = directory.resolve(target.endpoint, connectionID: target.connectionID) else {
            error = "The agent changed. Refresh the machine list."
            return
        }
        stop()
        remoteContext = nil
        socketPath = path
        selectedMachineEndpoint = target.endpoint
        machineConnectionID = target.connectionID
        pendingMachineResource = target
        error = nil
        start()
    }


    func select(paneID: String) {
        perform("pane.focus", params: ["pane_id": .string(paneID)])
    }

    func invoke(_ invocation: EndpointCommandInvocation) -> Bool {
        guard !busy, error == nil, methods.contains("command.invoke"), let snapshot,
              (try? invocation.validate(in: snapshot)) != nil else { return false }
        perform("command.invoke", params: invocation.params)
        return true
    }

    @discardableResult
    func performLayout(_ request: EndpointLayoutRequest, owningViewID: UUID? = nil) -> Bool {
        guard !busy, error == nil, let endpoint, let snapshot,
              request.owningViewID == (owningViewID ?? generation),
              request.action.method == "pane.move" || methods.contains(request.action.method),
              (try? request.validate(in: snapshot)) != nil else { return false }
        busy = true; layoutResult = nil; inputEpoch = UUID()
        let previousInput = inputTask, generation = generation, path = socketPath
        let client = HerdrPinnedRPC()
        layoutClient = client
        actionTask = Task { [weak self] in
            defer {
                client.cancel()
                if self?.generation == generation { self?.layoutClient = nil; self?.busy = false }
            }
            await previousInput?.value
            guard !Task.isCancelled, self?.generation == generation, let current = self?.snapshot else { return }
            var closed: [String] = []
            var moved = false
            do {
                try request.validate(in: current)
                let message: String
                switch request.action {
                case .closeWorkspace(let preview):
                    for id in try preview.closureOrder() {
                        guard !Task.isCancelled, self?.generation == generation, let current = self?.snapshot else { throw CancellationError() }
                        try request.validateClosureProgress(in: current, closed: closed)
                        let value = try await endpoint.request(method: "workspace.close",
                            params: ["workspace_id": .string(id), "close_group": .bool(false)], expectedBootID: request.bootID)
                        guard value.objectValue?["type"]?.stringValue == "ok" else { throw HerdrEndpointError.malformed }
                        closed.append(id)
                    }
                    message = "Closed \(closed.count) workspace(s)."
                case .movePane:
                    let rpc = request.rpc
                    let value = try await client.request(socketPath: path,
                        endpointSocketPath: RemoteConnection.clientSocketPath(for: path), bootID: request.bootID,
                        method: rpc.method, params: rpc.params, validate: { try request.validate(in: $0) })
                    guard !Task.isCancelled, self?.generation == generation else { return }
                    guard let paneID = try EndpointLayoutResult.movedPane(in: value, request: request) else {
                        self?.layoutResult = .init(requestID: request.id, message: "The server did not move the pane. Check the destination and zoom state.")
                        return
                    }
                    moved = true
                    guard !Task.isCancelled, self?.generation == generation, self?.snapshot?.bootID == request.bootID else { throw CancellationError() }
                    _ = try await endpoint.request(method: "pane.focus", params: ["pane_id": .string(paneID)], expectedBootID: request.bootID)
                    message = "Moved the pane. This view now follows it. Reopen Layout before another move."
                default:
                    let rpc = request.rpc
                    let value = try await endpoint.request(method: rpc.method, params: rpc.params, expectedBootID: request.bootID)
                    let unchanged = try !EndpointLayoutResult.changed(in: value, request: request)
                    message = unchanged ? "The layout did not change. Check the current position or split boundary." : "Updated the layout."
                }
                guard self?.generation == generation else { return }
                self?.layoutResult = .init(requestID: request.id, message: message)
            } catch {
                guard self?.generation == generation else { return }
                let prefix = moved ? "The pane moved, but this view could not select it. "
                    : "The action did not finish. Its last request may have completed. Inspect the layout before trying again. "
                let progress = closed.isEmpty ? "" : "Closed \(closed.count) reviewed workspace(s). "
                self?.layoutResult = .init(requestID: request.id, message: progress + prefix + error.localizedDescription, failed: true)
            }
        }
        return true
    }

    @discardableResult
    func performWorktree(_ request: EndpointWorktreeRequest) -> Bool {
        let rpc = request.operation.rpc
        guard !busy, error == nil, let endpoint, let snapshot, methods.contains(rpc.method),
              (try? request.validate(in: snapshot)) != nil else { return false }
        busy = true
        worktreeResult = nil
        inputEpoch = UUID()
        let previousInput = inputTask
        let generation = generation
        actionTask = Task { [weak self] in
            await previousInput?.value
            guard !Task.isCancelled, self?.generation == generation else { return }
            do {
                let result = try await endpoint.request(method: rpc.method, params: rpc.params, expectedBootID: request.bootID,
                    timeout: .seconds(60))
                let response = try EndpointWorktreeResult(request: request, result: result)
                guard self?.generation == generation else { return }
                if let paneID = response.navigationPaneID {
                    do {
                        // Deferred worktree completion can lose its original server navigation lease.
                        // A fresh request selects only this endpoint after successful creation/opening.
                        _ = try await endpoint.request(method: "pane.focus", params: ["pane_id": .string(paneID)], expectedBootID: request.bootID)
                    } catch {
                        guard self?.generation == generation else { return }
                        self?.worktreeResult = EndpointWorktreeResult(request: request,
                            error: "The worktree action completed, but this view could not select it. " + error.localizedDescription)
                        self?.busy = false
                        return
                    }
                }
                guard self?.generation == generation else { return }
                self?.worktreeResult = response
            } catch {
                guard self?.generation == generation else { return }
                self?.worktreeResult = EndpointWorktreeResult(request: request, error: error.localizedDescription)
            }
            self?.busy = false
        }
        return true
    }

    func performPlugin(_ request: EndpointPluginRequest) -> Bool {
        if case .installIntegration(let name) = request.operation, !dataPaths.canManageIntegration(name) {
            pluginResult = .init(requestID: request.id,
                error: "This integration requires a disposable test account. Its files cannot be isolated in this lab.")
            return true
        }
        if case .cancelInstall(let id) = request.operation, !usesRemoteHost {
            guard localPluginReviewID == id, request.bootID == snapshot?.bootID else { return false }
            if pluginRequestID == id {
                actionTask?.cancel()
                pluginClient?.cancel(); pluginClient = nil
                pluginRequestID = nil; busy = false
            }
            localPluginReviewID = nil
            let installPlugin = installPlugin, path = socketPath, boot = snapshot?.bootID ?? ""
            Task { _ = try? await installPlugin(.cancelInstall(id), path, boot) }
            pluginResult = .init(requestID: request.id, value: .object(["output": .string("Plugin review cancelled.")]))
            return true
        }
        if case .confirmInstall(let id) = request.operation, !usesRemoteHost,
           localPluginReviewID != id { return false }
        let cancellingRemote: Bool
        if case .cancelInstall = request.operation { cancellingRemote = remotePluginInstaller != nil }
        else { cancellingRemote = false }
        guard !busy || cancellingRemote, error == nil || cancellingRemote,
              let endpoint, let snapshot, request.bootID == snapshot.bootID else { return false }
        if let method = request.operation.endpointMethod, !methods.contains(method) { return false }
        if case .openPane(let invocation) = request.operation {
            guard (try? invocation.validate(in: snapshot)) != nil else { return false }
        }
        if case .activateLink(let invocation) = request.operation {
            guard let surface, (try? invocation.validate(in: surface)) != nil else {
                pluginResult = .init(requestID: request.id, error: HerdrEndpointError.staleIdentity.localizedDescription)
                return false
            }
        }
        if usesRemoteHost {
            switch request.operation {
            case .prepareInstall, .confirmInstall, .cancelInstall, .uninstall:
                return performRemotePlugin(request)
            default: break
            }
        }
        busy = true
        pluginResult = nil
        pluginRequestID = request.id
        if case .prepareInstall = request.operation { localPluginReviewID = request.id }
        let installPlugin = installPlugin
        let generation = generation
        let path = socketPath
        let client = HerdrPinnedRPC()
        pluginClient = client
        actionTask = Task { [weak self] in
            defer {
                client.cancel()
                if self?.generation == generation, self?.pluginRequestID == request.id {
                    self?.pluginClient = nil; self?.pluginRequestID = nil; self?.busy = false
                }
            }
            do {
                guard self?.generation == generation, self?.pluginRequestID == request.id,
                      self?.error == nil, !Task.isCancelled else { return }
                let value: JSONValue
                switch request.operation {
                case .openPane(let invocation):
                    value = try await endpoint.openPluginPane(invocation)
                case .prepareInstall, .confirmInstall, .cancelInstall, .uninstall:
                    value = try await installPlugin(request.operation, path, request.bootID)
                default:
                    let rpc = try request.operation.rpc()
                    if request.operation.endpointMethod != nil {
                        value = try await endpoint.request(method: rpc.method, params: rpc.params, expectedBootID: request.bootID)
                    } else {
                        value = try await client.request(socketPath: path,
                            endpointSocketPath: RemoteConnection.clientSocketPath(for: path),
                            bootID: request.bootID, method: rpc.method, params: rpc.params,
                            validate: { _ in })
                    }
                }
                guard self?.generation == generation, self?.pluginRequestID == request.id, !Task.isCancelled else {
                    if case .prepareInstall = request.operation,
                       let id = value.objectValue?["preview_id"]?.stringValue.flatMap(UUID.init(uuidString:)) {
                        _ = try? await installPlugin(.cancelInstall(id), path, request.bootID)
                    }
                    return
                }
                if case .prepareInstall = request.operation {
                    self?.localPluginReviewID = value.objectValue?["preview_id"]?.stringValue.flatMap(UUID.init(uuidString:))
                } else if case .confirmInstall = request.operation { self?.localPluginReviewID = nil }
                self?.pluginResult = .init(requestID: request.id, value: value)
            } catch {
                guard self?.generation == generation, self?.pluginRequestID == request.id, !Task.isCancelled else { return }
                if case .prepareInstall = request.operation { self?.localPluginReviewID = nil }
                self?.pluginResult = .init(requestID: request.id, error: error.localizedDescription)
            }
        }
        return true
    }

    @discardableResult
    func performTerminalAction(_ request: EndpointTextRequest) -> Bool {
        guard !busy, error == nil, let endpoint, let snapshot else { return false }
        if let rpc = request.historyRPC, !methods.contains(rpc.method) { return false }
        do {
            if request.historyRPC != nil { _ = try request.refreshedHistory(snapshot: snapshot, surface: surface) }
            else { try request.validate(snapshot: snapshot, surface: surface) }
        } catch {
            terminalResult = EndpointTextResult(requestID: request.id, error: error.localizedDescription)
            return true
        }
        busy = true
        terminalResult = nil
        inputEpoch = UUID()
        let previousInput = inputTask
        let generation = generation
        let client = HerdrPinnedRPC()
        let path = socketPath
        textClient = client
        actionTask = Task { [weak self] in
            defer {
                client.cancel()
                if self?.generation == generation { self?.textClient = nil; self?.busy = false }
            }
            await previousInput?.value
            guard !Task.isCancelled, self?.generation == generation else { return }
            do {
                let result: EndpointTextResult
                if request.historyRPC != nil {
                    result = try await endpoint.readHistory(request)
                } else if case .prompt(let text) = request.action {
                    let value = try await client.request(socketPath: path,
                        endpointSocketPath: RemoteConnection.clientSocketPath(for: path), bootID: request.bootID,
                        method: "agent.prompt", params: ["target": .string(request.paneID), "text": .string(text)],
                        validate: { try request.validate(snapshot: $0, surface: nil) })
                    guard value.objectValue?["type"]?.stringValue == "agent_prompted" else { throw HerdrEndpointError.malformed }
                    result = EndpointTextResult(requestID: request.id, text: "Prompt submitted.")
                } else { throw HerdrEndpointError.malformed }
                guard self?.generation == generation else { return }
                self?.terminalResult = result
            } catch {
                guard self?.generation == generation else { return }
                if case .prompt = request.action {
                    self?.terminalResult = .promptFailure(error, requestID: request.id)
                } else {
                    self?.terminalResult = EndpointTextResult(requestID: request.id, error: error.localizedDescription)
                }
            }
        }
        return true
    }

    private func performRemotePlugin(_ request: EndpointPluginRequest) -> Bool {
        guard usesRemoteHost else { return false }
        do {
            switch request.operation {
            case .confirmInstall(let id), .cancelInstall(let id):
                guard let installer = remotePluginInstaller else { throw HerdrEndpointError.staleIdentity }
                busy = true
                pluginResult = nil
                let approve: Bool
                if case .confirmInstall = request.operation { approve = true } else { approve = false }
                try installer.answer(request, previewID: id, approve: approve)
            case .prepareInstall(let source, let reference):
                guard !source.isEmpty, source.utf8.count <= 1024, reference.utf8.count <= 1024,
                      !source.hasPrefix("-"), !source.contains("\n"), !reference.contains("\n") else {
                    throw HerdrEndpointError.malformed
                }
                var arguments = ["plugin", "install", source]
                if !reference.isEmpty { arguments += ["--ref", reference] }
                try startRemotePlugin(request, arguments: arguments)
            case .uninstall(let id):
                guard !id.isEmpty, !id.hasPrefix("-"), id.utf8.count <= 1024 else { throw HerdrEndpointError.malformed }
                try startRemotePlugin(request, arguments: ["plugin", "uninstall", id])
            default: return false
            }
            return true
        } catch {
            remotePluginInstaller?.cancel()
            remotePluginInstaller = nil
            busy = false
            pluginResult = .init(requestID: request.id, error: error.localizedDescription)
            return true
        }
    }

    private func startRemotePlugin(_ request: EndpointPluginRequest, arguments: [String]) throws {
        let context = remoteContext, selected = machineEndpoint, connectionID = machineConnectionID
        let ssh: [String]
        if let context {
            guard remoteTunnel?.isRunning == true else { throw HerdrEndpointError.staleIdentity }
            ssh = try RemoteConnection.foregroundArguments(target: context.target, sessionName: context.sessionName, arguments: arguments)
        } else {
            guard let selected, let connectionID else { throw HerdrEndpointError.staleIdentity }
            ssh = try MachineDirectory.shared.sshCommand(endpoint: selected, connectionID: connectionID, arguments: arguments)
        }
        remotePluginInstaller?.cancel()
        busy = true
        pluginResult = nil
        let generation = generation
        let path = socketPath
        let installer = EndpointRemotePluginInstaller(request: request, isCurrent: { [weak self] in
            guard let self, self.generation == generation, self.snapshot?.bootID == request.bootID else { return false }
            if let context { return self.remoteContext == context && self.remoteTunnel?.isRunning == true }
            guard let selected, let connectionID else { return false }
            return MachineDirectory.shared.resolve(selected, connectionID: connectionID) == path
        }, deliver: { [weak self] result in
            guard self?.generation == generation else { return }
            self?.pluginResult = result
            self?.busy = false
        })
        remotePluginInstaller = installer
        try installer.start(arguments: ssh)
    }

    func perform(_ method: String, params: [String: JSONValue] = [:]) {
        guard !busy, let endpoint, let snapshot else { return }
        busy = true
        inputEpoch = UUID()
        let previousInput = inputTask
        let generation = generation
        actionTask = Task { [weak self] in
            do {
                await previousInput?.value
                guard !Task.isCancelled, self?.generation == generation else { return }
                _ = try await endpoint.request(method: method, params: params, expectedBootID: snapshot.bootID)
                if self?.generation == generation { self?.busy = false }
            } catch { self?.record(error, generation: generation) }
        }
    }

    func scroll(paneID: String, offset: UInt64) {
        guard surface?.popup == nil, error == nil, !busy || scrolling, let endpoint, let snapshot,
              methods.contains("pane.scroll"),
              let pane = surface?.panes.first(where: { $0.paneID == paneID }), let metrics = pane.scroll else { return }
        scrollTargets[paneID] = min(offset, metrics.maximum, EndpointScroll.maximumOffset)
        scrollActivity[paneID, default: 0] &+= 1
        guard !scrolling else { return }
        scrolling = true
        busy = true
        let generation = generation
        let previousInput = inputTask
        actionTask = Task { [weak self] in
            await previousInput?.value
            guard let self else { return }
            defer {
                if self.generation == generation { scrolling = false; busy = false; scrollTargets = [:] }
            }
            do {
                while self.generation == generation, !Task.isCancelled, let target = scrollTargets.first {
                    let rpc = EndpointBridgeCommand.scroll(paneID: target.key, offset: target.value).rpc
                    _ = try await endpoint.request(method: rpc.method, params: rpc.params, expectedBootID: snapshot.bootID)
                    guard self.generation == generation else { return }
                    if scrollTargets[target.key] == target.value { scrollTargets.removeValue(forKey: target.key) }
                }
            } catch { record(error, generation: generation) }
        }
    }

    func scrollPage(_ direction: Int) {
        guard let pane = surface?.panes.first(where: \.focused), let metrics = pane.scroll else { return }
        let lines = direction * Int(min(metrics.rows, 120))
        scroll(paneID: pane.paneID, offset: EndpointScroll.offset(from: metrics.offset, lines: lines, maximum: metrics.maximum))
    }

    func resize(columns: Int, rows: Int) {
        let next = (columns: UInt16(clamping: max(1, min(columns, 512))), rows: UInt16(clamping: max(1, min(rows, 128))))
        guard size?.columns != next.columns || size?.rows != next.rows else { return }
        size = next
        guard let endpoint, snapshot != nil, resizeTask == nil else { return }
        let generation = generation
        resizeTask = Task { [weak self] in
            defer { if self?.generation == generation { self?.resizeTask = nil } }
            while !Task.isCancelled, self?.generation == generation, let size = self?.size {
                do { try await endpoint.resize(columns: size.columns, rows: size.rows) }
                catch { self?.record(error, generation: generation); return }
                if self?.size?.columns == size.columns, self?.size?.rows == size.rows { return }
            }
        }
    }

    func send(_ bytes: ArraySlice<UInt8>) {
        guard let text = String(bytes: bytes, encoding: .utf8) else { error = "The keyboard sent invalid text."; return }
        send(text, paste: false)
    }

    func send(_ text: String, paste: Bool) {
        send(paste ? .paste(text) : .text(text))
    }

    func send(_ input: EndpointInput, paneID: String? = nil, bootID: String? = nil, projectionRevision: UInt64? = nil) {
        guard acceptsInput, let endpoint, let snapshot, let pane = snapshot.focusedPaneID else { return }
        guard paneID == nil || paneID == pane, bootID == nil || bootID == snapshot.bootID else {
            error = HerdrEndpointError.staleIdentity.localizedDescription
            return
        }
        let revision = projectionRevision ?? snapshot.revision
        let popupID = surface?.popup?.terminalID
        let byteCount = input.byteCount
        let lease = InputLease(paneID: pane, bootID: snapshot.bootID, revision: revision,
                               popupID: popupID, epoch: inputEpoch)
        if case .text(let text) = input, text.utf8.count <= 1_000_000 - queuedInputBytes,
           pendingText?.append(text, context: lease) == true {
            queuedInputBytes += text.utf8.count
            return
        }
        guard queuedInputs < 64, byteCount <= 1_000_000 - queuedInputBytes else {
            error = "Terminal input is full. Reconnect before sending more text."
            endpoint.disconnect()
            return
        }
        let batch: EndpointTextBatch<InputLease>?
        if case .text(let text) = input { batch = EndpointTextBatch(context: lease, text: text) }
        else { batch = nil }
        pendingText = batch
        queuedInputs += 1
        queuedInputBytes += byteCount
        let previous = inputTask, generation = generation, inputEpoch = inputEpoch
        inputTask = Task { [weak self] in
            defer {
                if self?.generation == generation {
                    self?.queuedInputs -= 1
                    self?.queuedInputBytes -= batch?.byteCount ?? byteCount
                }
            }
            await previous?.value
            guard !Task.isCancelled, self?.generation == generation, self?.inputEpoch == inputEpoch else { return }
            if self?.pendingText === batch { self?.pendingText = nil }
            let committed = batch.map { EndpointInput.text($0.seal()) } ?? input
            do {
                try await endpoint.sendInput(committed, paneID: pane, bootID: snapshot.bootID, projectionRevision: revision, popupID: popupID)
            } catch { self?.record(error, generation: generation) }
        }
    }

    func launchAgent(_ request: EndpointAgentLaunchRequest, owningViewID: UUID? = nil) -> Bool {
        guard !busy, error == nil, let snapshot, let endpoint,
              request.owningViewID == (owningViewID ?? generation),
              (try? request.validate(in: snapshot)) != nil else { return false }
        busy = true
        agentLaunchResult = nil
        inputEpoch = UUID()
        let previousInput = inputTask
        let generation = generation
        let path = socketPath
        let client = HerdrPinnedRPC()
        agentLaunchClient = client
        actionTask = Task { [weak self] in
            defer {
                client.cancel()
                if self?.generation == generation { self?.busy = false; self?.agentLaunchClient = nil }
            }
            do {
                await previousInput?.value
                guard !Task.isCancelled, self?.generation == generation else { return }
                let value = try await client.request(socketPath: path,
                    endpointSocketPath: RemoteConnection.clientSocketPath(for: path), bootID: request.bootID,
                    method: "agent.start", params: request.params, validate: { try request.validate(in: $0) })
                guard self?.generation == generation, !Task.isCancelled else { return }
                let result = try await request.resultAfterLaunch(value) {
                    _ = try await endpoint.request(method: "pane.focus", params: ["pane_id": .string(request.paneID)], expectedBootID: request.bootID)
                }
                guard self?.generation == generation, !Task.isCancelled else { return }
                self?.agentLaunchResult = result
            } catch {
                guard self?.generation == generation else { return }
                self?.agentLaunchResult = .init(requestID: request.id,
                    message: "The launch did not complete. Review the terminal before trying again. \(error.localizedDescription)", succeeded: false)
            }
        }
        return true
    }

    private func record(_ error: Error, generation: UUID) {
        guard self.generation == generation else { return }
        self.error = error.localizedDescription
        windowTitle = nil
        busy = false
    }
}
