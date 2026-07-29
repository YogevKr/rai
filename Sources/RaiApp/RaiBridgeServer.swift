import Foundation
import Network
import RaiCore
import SystemConfiguration

/// Token-authenticated WebSocket bridge from companion devices to RaiModel's
/// current herdr session.
///
/// The bridge uses cleartext WebSocket on the LAN. When available, Tailscale
/// Serve adds a TLS-terminated tailnet endpoint for off-LAN connections.
@MainActor
final class RaiBridgeServer: ObservableObject {
    // 8787 collided with common dev servers (e.g. bun); 47837 is an uncommon
    // registered-range port far from the usual suspects.
    static let defaultPort: UInt16 = 47837

    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var connectedDeviceCount = 0
    @Published private(set) var pairingToken: String
    @Published private(set) var registeredPushDeviceCount = 0
    @Published private(set) var tailscaleHost: String?

    let apnsSettings: APNsSettings
    let tailscalePort: UInt16 = 8443

    var isEnabled: Bool {
        get { userDefaults.bool(forKey: Self.enabledKey) }
        set {
            userDefaults.set(newValue, forKey: Self.enabledKey)
            newValue ? start() : stop()
        }
    }

    /// A hostname the phone can actually resolve over the LAN. The friendly
    /// computer name (`Host.localizedName`, e.g. "Yogev's MacBook Pro") is NOT a
    /// valid mDNS host — its spaces and apostrophe break resolution — so use the
    /// Bonjour LocalHostName ("Yogevs-MacBook-Pro.local").
    ///
    /// Tailscale reach is deliberately NOT advertised here: macOS Tailscale runs
    /// in userspace, so a raw tailnet port isn't reachable without
    /// `tailscale serve` in front of it (that's how collie exposes its bridge) —
    /// advertising the bare 100.x address just yields a connection that times out.
    var displayHost: String {
        if let local = SCDynamicStoreCopyLocalHostName(nil) as String?, !local.isEmpty {
            return "\(local).local"
        }
        let name = ProcessInfo.processInfo.hostName
        return name.hasSuffix(".local") ? name : "\(name).local"
    }

    var port: UInt16 {
        // Dev/test override so an isolated second instance can run its bridge
        // off the default port without colliding with a primary rai.
        if let raw = ProcessInfo.processInfo.environment["RAI_BRIDGE_PORT"],
           let override = UInt16(raw) {
            return override
        }
        return Self.defaultPort
    }

    var pairingURL: URL? {
        makePairingURL(host: displayHost, port: port, useTLS: false)
    }

    var tailscalePairingURL: URL? {
        guard let tailscaleHost else { return nil }
        return makePairingURL(host: tailscaleHost, port: tailscalePort, useTLS: true)
    }

    var tailscaleWSSURL: URL? {
        guard let tailscaleHost else { return nil }
        var components = URLComponents()
        components.scheme = "wss"
        components.host = tailscaleHost
        components.port = Int(tailscalePort)
        components.path = "/"
        return components.url
    }

    private func makePairingURL(host: String, port: UInt16, useTLS: Bool) -> URL? {
        var components = URLComponents()
        components.scheme = "rai"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "token", value: pairingToken),
        ]
        if useTLS {
            components.queryItems?.append(URLQueryItem(name: "tls", value: "1"))
        }
        return components.url
    }

    private static let enabledKey = "companionBridgeEnabled"
    private static let tokenKey = "companionBridgePairingToken"
    private static let pushRegistrationsKey = "companionBridgePushRegistrations"
    private unowned let model: RaiModel
    private let userDefaults: UserDefaults
    private let queue = DispatchQueue(label: "ai.sawmills.rai.bridge")
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: BridgeClient] = [:]
    private var observeStreams: [ObjectIdentifier: [String: ObserveStream]] = [:]
    private var pushRegistrations: Set<PushRegistration> = []
    /// Pushes delivered since a phone last connected; sent as the APNs badge
    /// so the app icon shows how many notifications await. Reset when a
    /// client authenticates — opening the app reconnects the bridge, which
    /// is the closest signal we have for "the user looked".
    private var outstandingPushCount = 0
    private let apnsPusher = APNsPusher()
    private let tailscaleServe = TailscaleServeController()
    private var tailscaleTask: Task<Void, Never>?

    init(
        model: RaiModel,
        userDefaults: UserDefaults = .standard,
        apnsSettings: APNsSettings? = nil
    ) {
        self.model = model
        self.userDefaults = userDefaults
        self.apnsSettings = apnsSettings ?? .shared
        if let saved = userDefaults.string(forKey: Self.tokenKey), !saved.isEmpty {
            pairingToken = saved
        } else {
            let token = Self.makeToken()
            pairingToken = token
            userDefaults.set(token, forKey: Self.tokenKey)
        }
        if let data = userDefaults.data(forKey: Self.pushRegistrationsKey),
           let saved = try? JSONDecoder().decode(Set<PushRegistration>.self, from: data) {
            pushRegistrations = saved
            registeredPushDeviceCount = saved.count
        }
    }

    func startIfEnabled() {
        if isEnabled {
            start()
        }
    }

    func start() {
        guard listener == nil else { return }
        do {
            let webSocket = NWProtocolWebSocket.Options()
            webSocket.autoReplyPing = true
            let parameters = NWParameters.tcp
            parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                statusMessage = "Invalid bridge port \(port)."
                return
            }
            let listener = try NWListener(using: parameters, on: nwPort)
            listener.service = NWListener.Service(name: "rai", type: "_rai._tcp")
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.listenerDidChange(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            self.listener = listener
            listener.start(queue: queue)
            startTailscaleServe()
        } catch {
            statusMessage = error.localizedDescription
            isRunning = false
        }
    }

    func stop() {
        let previousTailscaleTask = tailscaleTask
        previousTailscaleTask?.cancel()
        tailscaleHost = nil
        let tailscaleServe = tailscaleServe
        let tailscalePort = tailscalePort
        tailscaleTask = Task {
            await previousTailscaleTask?.value
            await tailscaleServe.stop(httpsPort: tailscalePort)
        }
        listener?.cancel()
        listener = nil
        stopAllObserveStreams()
        for client in clients.values {
            client.connection.cancel()
        }
        clients.removeAll()
        connectedDeviceCount = 0
        isRunning = false
    }

    func stopAndWait() async {
        stop()
        await tailscaleTask?.value
    }

    private func startTailscaleServe() {
        let previousTailscaleTask = tailscaleTask
        let tailscaleServe = tailscaleServe
        let bridgePort = port
        let tailscalePort = tailscalePort
        tailscaleTask = Task { [weak self] in
            await previousTailscaleTask?.value
            // "Unavailable" is often transient — tailscaled still coming up, a
            // slow spawn under load, Tailscale installed after rai. Retry with
            // backoff instead of leaving the Tailscale option missing until
            // the next bridge restart.
            var delay: Duration = .seconds(5)
            while !Task.isCancelled {
                let result = await tailscaleServe.start(
                    bridgePort: bridgePort,
                    httpsPort: tailscalePort
                )
                guard let self, !Task.isCancelled, self.listener != nil else {
                    await tailscaleServe.stop(httpsPort: tailscalePort)
                    return
                }
                switch result {
                case let .active(host):
                    self.tailscaleHost = host
                    return
                case let .failed(message):
                    // A real conflict (port taken, serve rejected) won't
                    // self-heal; surface it and stop retrying.
                    self.statusMessage = message
                    return
                case .unavailable:
                    break
                }
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(300))
            }
        }
    }

    func regenerateToken() {
        pairingToken = Self.makeToken()
        userDefaults.set(pairingToken, forKey: Self.tokenKey)
        // Authentication is connection-scoped, so changing the token also
        // disconnects already-paired devices immediately.
        stopAllObserveStreams()
        for client in clients.values {
            client.connection.cancel()
        }
        clients.removeAll()
        connectedDeviceCount = 0
        // Revoking bridge access must also revoke push delivery: a device that
        // can no longer connect (its token no longer matches) would otherwise
        // keep receiving pane names, workspace labels, and status pushes.
        pushRegistrations.removeAll()
        persistPushRegistrations()
    }

    func relay(events: [HerdrEvent]) {
        let subscribers = clients.values.filter(\.isSubscribed)
        guard !subscribers.isEmpty else { return }

        for event in events
        where event.name != "pane.output_changed" && event.name != "pane.updated" {
            // Structural event details are useful for diagnostics. The
            // authoritative state follows as a fresh snapshot from RaiModel.
            broadcast(
                .event(BridgeEvent(name: event.name, payload: event.data)),
                onlyToSubscribers: true
            )
        }
    }

    func relay(snapshot: SessionSnapshot) {
        broadcast(.snapshot(snapshot), onlyToSubscribers: true)
    }

    /// Pushes the panes' pending background work (⏳) to subscribed phones —
    /// summaries only, kind-labeled, so an idle-but-waiting agent reads as
    /// waiting instead of finished.
    func relay(backgroundWork: [String: [AgentBackgroundTask]]) {
        let work = backgroundWork
            .map { PaneBackgroundWork(paneID: $0.key, summaries: $0.value.map(\.displaySummary)) }
            .sorted { $0.paneID < $1.paneID }
        broadcast(.backgroundWork(work), onlyToSubscribers: true)
    }

    func sendPush(
        title: String,
        subtitle: String?,
        body: String,
        paneID: String,
        workspaceID: String,
        workspace: String?,
        requiresAttention: Bool
    ) {
        let configuration = apnsSettings.configuration
        let registrations = pushRegistrations
        guard !registrations.isEmpty else { return }
        guard configuration.isConfigured else {
            // A phone expects pushes but the APNs key is gone (e.g. removed
            // from the keychain). Losing them SILENTLY cost a debugging
            // session — say so where the bridge status is shown.
            statusMessage = "Push disabled: APNs auth key missing — re-add it in Settings."
            return
        }
        let pusher = apnsPusher
        outstandingPushCount += 1
        let badge = outstandingPushCount

        let delivery = Task.detached {
            await withTaskGroup(of: String?.self, returning: [String].self) { group in
                for registration in registrations {
                    group.addTask {
                        let result = await pusher.send(
                            configuration: configuration,
                            deviceToken: registration.deviceToken,
                            environment: registration.environment,
                            title: title,
                            subtitle: subtitle,
                            body: body,
                            paneID: paneID,
                            workspaceID: workspaceID,
                            workspace: workspace,
                            category: requiresAttention ? "agent-attention" : nil,
                            badge: badge
                        )
                        return result == .deadToken ? registration.deviceToken : nil
                    }
                }
                var deadTokens: [String] = []
                for await deadToken in group {
                    if let deadToken { deadTokens.append(deadToken) }
                }
                return deadTokens
            }
        }
        Task { [weak self] in
            for deadToken in await delivery.value {
                self?.removePushRegistration(deviceToken: deadToken)
            }
        }
    }

    private func listenerDidChange(_ state: NWListener.State) {
        switch state {
        case .ready:
            isRunning = true
            statusMessage = nil
        case .failed(let error):
            statusMessage = error.localizedDescription
            stop()
        case .cancelled:
            isRunning = false
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let client = BridgeClient(connection: connection)
        let id = ObjectIdentifier(connection)
        clients[id] = client
        connection.stateUpdateHandler = { [weak self] state in
            guard case .failed = state else {
                if case .cancelled = state {
                    Task { @MainActor in self?.removeClient(id) }
                }
                return
            }
            Task { @MainActor in self?.removeClient(id) }
        }
        connection.start(queue: queue)
        receive(from: client)
    }

    private func receive(from client: BridgeClient) {
        client.connection.receiveMessage { [weak self, weak client] data, context, _, error in
            guard let self, let client else { return }
            Task { @MainActor in
                guard self.clients[ObjectIdentifier(client.connection)] != nil else { return }
                if let error {
                    self.removeClient(ObjectIdentifier(client.connection))
                    self.statusMessage = error.localizedDescription
                    return
                }
                if let data,
                   let metadata = context?.protocolMetadata(
                       definition: NWProtocolWebSocket.definition
                   ) as? NWProtocolWebSocket.Metadata,
                   metadata.opcode == .text {
                    await self.handle(data, from: client)
                } else {
                    self.send(.error(message: "Only WebSocket text frames are supported."), to: client)
                }
                if self.clients[ObjectIdentifier(client.connection)] != nil {
                    self.receive(from: client)
                }
            }
        }
    }

    private func handle(_ data: Data, from client: BridgeClient) async {
        let message: BridgeMessage
        do {
            message = try JSONDecoder().decode(BridgeMessage.self, from: data)
        } catch {
            send(.error(message: "Invalid bridge message: \(error.localizedDescription)"), to: client)
            return
        }

        if !client.isAuthenticated {
            guard case let .hello(token, info) = message else {
                reject(client, reason: "hello must be the first message")
                return
            }
            guard token == pairingToken else {
                reject(client, reason: "Invalid pairing token")
                return
            }
            client.isAuthenticated = true
            outstandingPushCount = 0
            client.info = info
            updateConnectedDeviceCount()
            send(
                .welcome(
                    protocolVersion: bridgeProtocolVersion,
                    sessionName: model.currentSessionName
                ),
                to: client
            )
            return
        }

        switch message {
        case .subscribe:
            client.isSubscribed = true
            if let snapshot = model.snapshot {
                send(.snapshot(snapshot), to: client)
            } else {
                send(.error(message: "Herdr is not connected."), to: client)
            }
        case let .attachStream(paneID, cols, rows, fullGrid):
            guard client.isSubscribed else {
                send(.error(message: "Subscribe before attaching a pane stream."), to: client)
                return
            }
            guard cols > 0, rows > 0 else {
                send(.error(message: "Pane dimensions must be positive."), to: client)
                return
            }
            startObserveStream(
                paneID: paneID, cols: cols, rows: rows, fullGrid: fullGrid, for: client)
        case let .detachStream(paneID):
            stopObserveStream(paneID: paneID, for: client)
        case let .input(paneID, bytesBase64):
            guard let data = Data(base64Encoded: bytesBase64) else {
                send(.error(message: "input bytesBase64 is invalid."), to: client)
                return
            }
            await perform(for: client) {
                try await self.model.client.sendInput(paneID: paneID, bytes: [UInt8](data))
            }
        case let .sendImage(paneID, bytesBase64, filename):
            guard let data = Data(base64Encoded: bytesBase64), !data.isEmpty else {
                send(.error(message: "sendImage bytesBase64 is invalid."), to: client)
                return
            }
            guard data.count <= 5 * 1_024 * 1_024 else {
                send(.error(message: "Images must be 5 MB or smaller."), to: client)
                return
            }
            await perform(for: client) {
                let url = try self.writeTemporaryImage(data, filename: filename)
                let path = url.path.replacingOccurrences(of: " ", with: "\\ ")
                try await self.model.client.sendInput(
                    paneID: paneID,
                    bytes: [UInt8]("\(path) ".utf8)
                )
            }
        case let .focusPane(paneID):
            await perform(for: client) {
                try await self.model.client.focusPane(paneID)
            }
        case let .renameWorkspace(workspaceID, label):
            model.renameWorkspaceFromBridge(workspaceID: workspaceID, label: label)
        case let .closeWorkspace(workspaceID):
            model.closeWorkspaceFromBridge(workspaceID: workspaceID)
        case let .broadcastInput(tabID, text):
            model.broadcastFromBridge(tabID: tabID, text: text)
        case .listSessions:
            send(.sessions(model.bridgeSessionList()), to: client)
        case let .selectSession(name):
            model.selectSessionFromBridge(named: name)
        case let .selectPane(paneID):
            guard model.snapshot?.panes.contains(where: { $0.paneID == paneID }) == true else {
                send(.error(message: "Unknown pane \(paneID)."), to: client)
                return
            }
            model.select(paneID: paneID, focusInHerdr: true)
        case let .resizePane(paneID, cols, rows):
            guard cols > 0, rows > 0 else {
                send(.error(message: "Pane dimensions must be positive."), to: client)
                return
            }
            let clientID = ObjectIdentifier(client.connection)
            // A restarted stream keeps the attach-time full-grid opt-in.
            guard let existing = observeStreams[clientID]?[paneID] else { return }
            startObserveStream(
                paneID: paneID, cols: cols, rows: rows, fullGrid: existing.fullGrid, for: client)
        case let .launchAgent(workspaceID, agent, cwd):
            if let workspaceID,
               model.snapshot?.workspaces.contains(where: {
                   $0.workspaceID == workspaceID
               }) != true {
                send(.error(message: "Unknown workspace \(workspaceID)."), to: client)
                return
            }
            // "terminal" is a plain shell pane, not an agent — routed through
            // the same message so older phones and Macs stay compatible.
            if agent == "terminal" {
                guard await model.createTerminalFromBridge(workspaceID: workspaceID, cwd: cwd)
                else {
                    send(.error(message: "Could not launch \(agent)."), to: client)
                    return
                }
                return
            }
            guard let kind = AgentLaunchKind(rawValue: agent) else {
                send(.error(message: "Agent must be claude or codex."), to: client)
                return
            }
            guard await model.launchAgentFromBridge(kind, workspaceID: workspaceID, cwd: cwd)
            else {
                send(.error(message: "Could not launch \(agent)."), to: client)
                return
            }
        case let .renamePane(paneID, label):
            guard await model.renamePaneFromBridge(paneID: paneID, label: label) else {
                send(.error(message: "Could not rename pane \(paneID)."), to: client)
                return
            }
        case let .renameTab(tabID, label):
            guard await model.renameTabFromBridge(tabID: tabID, label: label) else {
                send(.error(message: "Could not rename tab \(tabID)."), to: client)
                return
            }
        case let .closePane(paneID):
            guard await model.closePaneFromBridge(paneID: paneID) else {
                send(.error(message: "Could not close pane \(paneID)."), to: client)
                return
            }
        case let .closeTab(tabID):
            guard await model.closeTabFromBridge(tabID: tabID) else {
                send(.error(message: "Could not close tab \(tabID)."), to: client)
                return
            }
        case let .sendKeys(paneID, keys):
            guard !keys.isEmpty, keys.count <= 8 else {
                send(.error(message: "sendKeys takes 1-8 keys."), to: client)
                return
            }
            await perform(for: client) {
                try await self.model.client.sendKeys(paneID: paneID, keys: keys)
            }
        case let .readScrollback(paneID, lines, rows, fullGrid):
            guard let pane = model.snapshot?.panes.first(where: { $0.paneID == paneID }) else {
                send(.error(message: "Unknown pane \(paneID)."), to: client)
                return
            }
            // A full-grid client's frame stream repaints the pane's WHOLE
            // grid, so the seed must drop that many rows from the tail — not
            // just the client's screenful — or the seam duplicates the rows
            // between viewport height and pane height.
            let seamRows = fullGrid ? max(rows, pane.scroll?.viewportRows ?? rows) : rows
            // Awaited inline so the reply reaches the client before any
            // subsequent attachStream starts its frame stream — the phone
            // relies on scrollback arriving before the first full frame.
            let payload = await readScrollbackPayload(
                paneID: paneID,
                lines: min(max(lines, 1), 2_000),
                clientRows: min(max(seamRows, 0), 200)
            )
            guard let payload else {
                send(.error(message: "Could not read scrollback for \(paneID)."), to: client)
                return
            }
            send(
                .scrollback(paneID: paneID, bytesBase64: payload.base64EncodedString()),
                to: client
            )
        case let .registerPush(deviceToken, environment):
            guard environment == "sandbox" || environment == "production" else {
                send(.error(message: "Push environment must be sandbox or production."), to: client)
                return
            }
            let normalizedToken = deviceToken.lowercased()
            guard normalizedToken.count == 64,
                  normalizedToken.allSatisfy(\.isHexDigit)
            else {
                send(.error(message: "Push device token must be 64 hexadecimal characters."), to: client)
                return
            }
            registerPush(deviceToken: normalizedToken, environment: environment)
        case let .unregisterPush(deviceToken):
            removePushRegistration(deviceToken: deviceToken.lowercased())
        case .hello:
            send(.error(message: "Connection is already authenticated."), to: client)
        case .welcome, .authFailed, .snapshot, .event, .paneFrame, .scrollback, .error,
             .backgroundWork, .sessions:
            send(.error(message: "Server-to-client message received from client."), to: client)
        }
    }

    /// Recent pane history from herdr, ANSI-formatted, with the client's
    /// screenful dropped from the tail — the live frame stream repaints the
    /// last `clientRows` lines, and keeping them would show that screen twice
    /// at the seam between seeded history and the live grid.
    private func readScrollbackPayload(
        paneID: String,
        lines: Int,
        clientRows: Int
    ) async -> Data? {
        guard let recent = await Self.runHerdrCapture([
            "pane", "read", paneID,
            "--source", "recent", "--lines", String(lines), "--format", "ansi",
        ]), let recentText = String(data: recent, encoding: .utf8) else {
            return nil
        }
        // Shell panes come back CRLF-terminated, and Swift treats "\r\n" as a
        // single grapheme — split(separator: "\n") sees ONE line and the
        // dropLast wipes the whole payload. Normalize endings first.
        let normalized = recentText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let history = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast(clientRows)
            .joined(separator: "\n")
        guard !history.isEmpty else { return Data() }
        // Trailing attribute reset so partial styling can't bleed into the
        // live frames fed after this history.
        return Data((history + "\n\u{1B}[0m").utf8)
    }

    private static func runHerdrCapture(_ arguments: [String]) async -> Data? {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: HerdrCLI.binaryPath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // Drain stdout concurrently with the exit wait: the payload can exceed
        // the pipe buffer, and reading only after exit would deadlock herdr.
        let data = await Task.detached {
            stdout.fileHandleForReading.readDataToEndOfFile()
        }.value
        await Task.detached { process.waitUntilExit() }.value
        return process.terminationStatus == 0 ? data : nil
    }

    private func writeTemporaryImage(_ data: Data, filename: String) throws -> URL {
        let stem = URL(fileURLWithPath: filename)
            .deletingPathExtension().lastPathComponent
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let safeStem = stem.isEmpty ? "rai-image" : stem
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rai-bridge-images", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent("\(safeStem)-\(UUID().uuidString).png")
        try data.write(to: url, options: .atomic)
        removeStaleImages(in: directory, keeping: url)
        return url
    }

    private func removeStaleImages(in directory: URL, keeping current: URL) {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for url in urls where url != current {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let date = values.contentModificationDate,
                  date < cutoff
            else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func startObserveStream(
        paneID: String,
        cols: Int,
        rows: Int,
        fullGrid: Bool,
        for client: BridgeClient
    ) {
        guard let pane = model.snapshot?.panes.first(where: { $0.paneID == paneID }) else {
            send(.error(message: "Unknown pane \(paneID)."), to: client)
            return
        }

        stopObserveStream(paneID: paneID, for: client)

        // herdr renders the observe frame as a top-left window of the pane's
        // grid, so a stream shorter than the pane silently drops the BOTTOM
        // rows — prompt and cursor included. For clients that opted in
        // (fullGrid), never stream fewer rows than the pane actually has; the
        // client scrolls a viewport over the full grid (frames carry their
        // dimensions so it knows the grid size). Legacy clients size their
        // emulator to the view and would garble a taller stream.
        let streamRows = fullGrid ? max(rows, pane.scroll?.viewportRows ?? rows) : rows

        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: HerdrCLI.binaryPath)
        process.arguments = [
            "terminal", "session", "observe", paneID,
            "--cols", String(cols), "--rows", String(streamRows),
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        let stream = ObserveStream(process: process, stdout: stdout, fullGrid: fullGrid)
        let clientID = ObjectIdentifier(client.connection)

        stdout.fileHandleForReading.readabilityHandler = { [weak self, weak client, weak stream] handle in
            guard let self, let client, let stream else { return }
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let frames = stream.consume(data)
            guard !frames.isEmpty else { return }
            Task { @MainActor in
                guard self.observeStreams[clientID]?[paneID] === stream else { return }
                for frame in frames {
                    self.send(
                        .paneFrame(
                            paneID: paneID,
                            bytesBase64: frame.bytes,
                            full: frame.full,
                            seq: frame.seq,
                            cols: frame.width,
                            rows: frame.height
                        ),
                        to: client
                    )
                }
            }
        }
        process.terminationHandler = { [weak self, weak client, weak stream] process in
            Task { @MainActor in
                guard let self, let client, let stream,
                      self.observeStreams[clientID]?[paneID] === stream
                else { return }
                self.removeObserveStream(paneID: paneID, clientID: clientID)
                if !stream.isStopping {
                    self.send(
                        .error(
                            message: "Pane stream \(paneID) exited with status \(process.terminationStatus)."
                        ),
                        to: client
                    )
                }
            }
        }

        observeStreams[clientID, default: [:]][paneID] = stream
        do {
            try process.run()
        } catch {
            removeObserveStream(paneID: paneID, clientID: clientID)
            send(
                .error(message: "Unable to start pane stream \(paneID): \(error.localizedDescription)"),
                to: client
            )
        }
    }

    private func stopObserveStream(paneID: String, for client: BridgeClient) {
        let clientID = ObjectIdentifier(client.connection)
        guard let stream = observeStreams[clientID]?[paneID] else { return }
        stream.stop()
        removeObserveStream(paneID: paneID, clientID: clientID)
    }

    private func removeObserveStream(paneID: String, clientID: ObjectIdentifier) {
        guard let stream = observeStreams[clientID]?.removeValue(forKey: paneID) else { return }
        stream.close()
        if observeStreams[clientID]?.isEmpty == true {
            observeStreams.removeValue(forKey: clientID)
        }
    }

    private func stopObserveStreams(for clientID: ObjectIdentifier) {
        guard let streams = observeStreams.removeValue(forKey: clientID) else { return }
        for stream in streams.values {
            stream.stop()
            stream.close()
        }
    }

    private func stopAllObserveStreams() {
        let streams = observeStreams.values.flatMap(\.values)
        observeStreams.removeAll()
        for stream in streams {
            stream.stop()
            stream.close()
        }
    }

    private func perform(
        for client: BridgeClient,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
        } catch {
            send(.error(message: error.localizedDescription), to: client)
        }
    }

    private func reject(_ client: BridgeClient, reason: String) {
        send(.authFailed(reason: reason), to: client) {
            client.connection.cancel()
        }
    }

    private func broadcast(_ message: BridgeMessage, onlyToSubscribers: Bool) {
        for client in clients.values
        where !onlyToSubscribers || client.isSubscribed {
            send(message, to: client)
        }
    }

    private func send(
        _ message: BridgeMessage,
        to client: BridgeClient,
        completion: (() -> Void)? = nil
    ) {
        do {
            let data = try JSONEncoder().encode(message)
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(
                identifier: "rai.bridge.message",
                metadata: [metadata]
            )
            client.connection.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { _ in
                    if let completion {
                        Task { @MainActor in completion() }
                    }
                }
            )
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func removeClient(_ id: ObjectIdentifier) {
        stopObserveStreams(for: id)
        clients.removeValue(forKey: id)
        updateConnectedDeviceCount()
    }

    private func updateConnectedDeviceCount() {
        connectedDeviceCount = clients.values.lazy.filter(\.isAuthenticated).count
    }

    private func registerPush(deviceToken: String, environment: String) {
        pushRegistrations = Set(pushRegistrations.filter { $0.deviceToken != deviceToken })
        pushRegistrations.insert(.init(deviceToken: deviceToken, environment: environment))
        persistPushRegistrations()
    }

    private func removePushRegistration(deviceToken: String) {
        let oldCount = pushRegistrations.count
        pushRegistrations = Set(pushRegistrations.filter { $0.deviceToken != deviceToken })
        if pushRegistrations.count != oldCount {
            persistPushRegistrations()
        }
    }

    private func persistPushRegistrations() {
        if let data = try? JSONEncoder().encode(pushRegistrations) {
            userDefaults.set(data, forKey: Self.pushRegistrationsKey)
        }
        registeredPushDeviceCount = pushRegistrations.count
    }

    private static func makeToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

private struct PushRegistration: Codable, Hashable, Sendable {
    let deviceToken: String
    let environment: String
}

private struct ObserveFrame: Decodable {
    let type: String
    let encoding: String
    let seq: Int
    let full: Bool
    let bytes: String
    let width: Int?
    let height: Int?
}

private final class ObserveStream: @unchecked Sendable {
    let process: Process
    let stdout: Pipe
    /// Whether the attaching client opted into pane-sized (full-grid) frames;
    /// restarts triggered by resizePane must preserve it.
    let fullGrid: Bool
    private var buffer = Data()
    private(set) var isStopping = false

    init(process: Process, stdout: Pipe, fullGrid: Bool) {
        self.process = process
        self.stdout = stdout
        self.fullGrid = fullGrid
    }

    func consume(_ data: Data) -> [ObserveFrame] {
        buffer.append(data)
        var frames: [ObserveFrame] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let frame = try? JSONDecoder().decode(ObserveFrame.self, from: line),
                  frame.type == "terminal.frame",
                  frame.encoding == "ansi"
            else { continue }
            frames.append(frame)
        }
        return frames
    }

    @MainActor
    func stop() {
        isStopping = true
        stdout.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
        }
    }

    @MainActor
    func close() {
        stdout.fileHandleForReading.readabilityHandler = nil
        try? stdout.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
    }
}

private final class BridgeClient: @unchecked Sendable {
    let connection: NWConnection
    var isAuthenticated = false
    var isSubscribed = false
    var info: ClientInfo?

    init(connection: NWConnection) {
        self.connection = connection
    }
}
