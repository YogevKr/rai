import Foundation
import Network
import RaiCore
import SystemConfiguration

struct PushDeliveryReport: Identifiable, Equatable, Sendable {
    let deviceToken: String
    let environment: String
    let status: Int?
    let reason: String

    var id: String { "\(environment):\(deviceToken)" }
    var deviceLabel: String { "…\(deviceToken.suffix(8))" }
    var succeeded: Bool { status == 200 }
}

struct PushBadgeLedger<Device: Hashable> {
    private var activePushesByDevice: [Device: [Set<String>]] = [:]

    func proposedBadge(adding identifiers: Set<String>, for device: Device) -> Int {
        var active = activePushesByDevice[device] ?? []
        active.removeAll { !$0.isDisjoint(with: identifiers) }
        active.append(identifiers)
        return active.count
    }

    mutating func commitAlert(identifiers: Set<String>, for device: Device) {
        var active = activePushesByDevice[device] ?? []
        active.removeAll { !$0.isDisjoint(with: identifiers) }
        active.append(identifiers)
        activePushesByDevice[device] = active
    }

    mutating func commitRetraction(identifiers: Set<String>, for device: Device) {
        activePushesByDevice[device]?.removeAll {
            !$0.isDisjoint(with: identifiers)
        }
    }

    mutating func removeAll() {
        activePushesByDevice.removeAll()
    }

    mutating func removeDevices(where shouldRemove: (Device) -> Bool) {
        activePushesByDevice = activePushesByDevice.filter {
            !shouldRemove($0.key)
        }
    }
}

private struct RetractionDeliveryReport: Sendable {
    let pushReport: PushDeliveryReport
    let acceptedNotificationIDs: Set<String>
}

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
    @Published private(set) var tailscaleServeState: TailscaleServeState = .stopped
    @Published private(set) var isBonjourAdvertised = false
    @Published private(set) var testPushResults: [PushDeliveryReport] = []
    @Published private(set) var isSendingTestPush = false
    @Published private(set) var lastPushResult: String?
    @Published private(set) var lastPushSucceeded: Bool?

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
    /// Consecutive unexpected observe exits per (client, pane); reset when a
    /// stream produces frames again. Guards the auto-restart loop below.
    private var observeRestarts: [ObjectIdentifier: [String: Int]] = [:]
    private var pushRegistrations: Set<PushRegistration> = []
    /// Atomic delivered alerts per device. A summary counts as one alert.
    /// Opening any client resets this optimistic state, as before.
    private var pushBadgeLedger = PushBadgeLedger<PushRegistration>()
    private let apnsPusher = APNsPusher()
    /// Serializes alert, retraction, and test batches in their creation order.
    private var pushOperationTail: Task<Void, Never>?
    private let tailscaleServe = TailscaleServeController()
    private var tailscaleTask: Task<Void, Never>?
    private var registeredBonjourEndpoints: Set<NWEndpoint> = []

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
        tailscaleServeState = .checking
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
            listener.serviceRegistrationUpdateHandler = { [weak self] change in
                Task { @MainActor in self?.bonjourRegistrationDidChange(change) }
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
            tailscaleServeState = .stopped
        }
    }

    func stop() {
        let previousTailscaleTask = tailscaleTask
        previousTailscaleTask?.cancel()
        tailscaleHost = nil
        tailscaleServeState = .stopped
        registeredBonjourEndpoints.removeAll()
        isBonjourAdvertised = false
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
                    self.tailscaleServeState = .active(host: host)
                    return
                case let .failed(message):
                    // A real conflict (port taken, serve rejected) won't
                    // self-heal; surface it and stop retrying.
                    self.statusMessage = message
                    self.tailscaleServeState = .failed(message: message)
                    return
                case .unavailable:
                    self.tailscaleServeState = .unavailable
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
        restartStreamsWhosePaneResized(snapshot)
    }

    /// A full-grid stream renders at a fixed row count, so a pane resized on
    /// the Mac leaves the phone mirroring the OLD geometry — the same class of
    /// bug as streaming 40 rows of a 45-row pane. resizePane cannot catch this:
    /// it carries the CLIENT's viewport, which does not shape these streams.
    /// A fresh snapshot is the only signal that the pane itself changed.
    private func restartStreamsWhosePaneResized(_ snapshot: SessionSnapshot) {
        for (clientID, streams) in observeStreams {
            guard let client = clients[clientID] else { continue }
            for (paneID, stream) in streams where stream.fullGrid && stream.isRunning {
                guard let pane = snapshot.panes.first(where: { $0.paneID == paneID }),
                      let current = pane.scroll?.viewportRows,
                      current != stream.paneRows
                else { continue }
                startObserveStream(
                    paneID: paneID, cols: stream.cols, rows: stream.rows,
                    fullGrid: true, for: client
                )
            }
        }
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

    func sendPush(_ burst: PhonePushBurst) {
        let configuration = apnsSettings.configuration
        let registrations = pushRegistrations
        guard !registrations.isEmpty else {
            recordNoDelivery("Push not sent: no registered devices.")
            return
        }
        guard configuration.isConfigured else {
            // A phone expects pushes but the APNs key is gone (e.g. removed
            // from the keychain). Losing them SILENTLY cost a debugging
            // session — say so where the bridge status is shown.
            statusMessage = "Push disabled: APNs auth key missing — re-add it in Settings."
            recordNoDelivery("Push not sent: APNs configuration is incomplete.")
            return
        }
        let pusher = apnsPusher
        let stableIDs = Set(burst.notificationIDs)

        let previousOperation = pushOperationTail
        let operation = Task { [weak self] in
            await previousOperation?.value
            guard let self else { return }
            let badges = Dictionary(uniqueKeysWithValues: registrations.map {
                ($0, self.pushBadgeLedger.proposedBadge(adding: stableIDs, for: $0))
            })
            let reports = await withTaskGroup(
                of: PushDeliveryReport.self,
                returning: [PushDeliveryReport].self
            ) { group in
                for registration in registrations {
                    group.addTask {
                        let result = await pusher.sendAlert(
                            configuration: configuration,
                            deviceToken: registration.deviceToken,
                            environment: registration.environment,
                            title: burst.title,
                            subtitle: burst.workspaceName,
                            body: burst.body,
                            paneID: burst.paneID,
                            workspaceID: burst.workspaceID,
                            workspace: burst.workspaceName,
                            category: burst.requiresAttention ? "agent-attention" : nil,
                            notificationIDs: burst.notificationIDs,
                            threadID: burst.threadID,
                            summaryArgument: burst.summaryArgument,
                            summaryArgumentCount: burst.events.count,
                            occurredAt: burst.occurredAt,
                            badge: badges[registration]
                        )
                        return PushDeliveryReport(
                            deviceToken: registration.deviceToken,
                            environment: registration.environment,
                            status: result.status,
                            reason: result.reason
                        )
                    }
                }
                var values: [PushDeliveryReport] = []
                for await report in group {
                    values.append(report)
                }
                return values.sorted { $0.id < $1.id }
            }
            for report in reports where report.succeeded {
                self.pushBadgeLedger.commitAlert(
                    identifiers: stableIDs,
                    for: .init(
                        deviceToken: report.deviceToken,
                        environment: report.environment
                    )
                )
            }
            self.recordDelivery(reports)
            for report in reports where Self.isDeadToken(report) {
                self.removePushRegistration(deviceToken: report.deviceToken)
            }
        }
        pushOperationTail = operation
    }

    func retractPushNotifications(identifiers: [String]) {
        let identifiers = Array(Set(identifiers)).sorted()
        guard !identifiers.isEmpty else { return }
        let configuration = apnsSettings.configuration
        let registrations = pushRegistrations
        guard !registrations.isEmpty else { return }
        guard configuration.isConfigured else {
            recordNoDelivery("Retraction not sent: APNs configuration is incomplete.")
            return
        }
        let pusher = apnsPusher
        let retractedBefore = Date()
        let previousOperation = pushOperationTail
        let operation = Task { [weak self] in
            await previousOperation?.value
            let reports = await withTaskGroup(
                of: RetractionDeliveryReport.self,
                returning: [RetractionDeliveryReport].self
            ) { group in
                for registration in registrations {
                    group.addTask {
                        let result = await pusher.sendRetraction(
                            configuration: configuration,
                            deviceToken: registration.deviceToken,
                            environment: registration.environment,
                            notificationIDs: identifiers,
                            retractedBefore: retractedBefore
                        )
                        return RetractionDeliveryReport(
                            pushReport: .init(
                                deviceToken: registration.deviceToken,
                                environment: registration.environment,
                                status: result.status,
                                reason: result.reason
                            ),
                            acceptedNotificationIDs: result.acceptedNotificationIDs
                        )
                    }
                }
                var values: [RetractionDeliveryReport] = []
                for await report in group { values.append(report) }
                return values.sorted { $0.pushReport.id < $1.pushReport.id }
            }
            guard let self else { return }
            for report in reports where !report.acceptedNotificationIDs.isEmpty {
                self.pushBadgeLedger.commitRetraction(
                    identifiers: report.acceptedNotificationIDs,
                    for: .init(
                        deviceToken: report.pushReport.deviceToken,
                        environment: report.pushReport.environment
                    )
                )
            }
            let pushReports = reports.map(\.pushReport)
            self.recordDelivery(pushReports, label: "Retraction")
            for report in pushReports where Self.isDeadToken(report) {
                self.removePushRegistration(deviceToken: report.deviceToken)
            }
        }
        pushOperationTail = operation
    }

    func sendTestPush(now: Date = Date()) {
        let configuration = apnsSettings.configuration
        let registrations = pushRegistrations
        testPushResults = []
        guard !registrations.isEmpty else {
            recordNoDelivery("Test push not sent: no registered devices.")
            return
        }
        guard configuration.isConfigured else {
            recordNoDelivery("Test push not sent: APNs configuration is incomplete.")
            return
        }
        isSendingTestPush = true
        let pusher = apnsPusher
        let title = "rai test · \(Self.pushTime(now))"
        let previousOperation = pushOperationTail
        let operation = Task { [weak self] in
            await previousOperation?.value
            let reports = await withTaskGroup(
                of: PushDeliveryReport.self,
                returning: [PushDeliveryReport].self
            ) { group in
                for registration in registrations {
                    group.addTask {
                        let result = await pusher.sendAlert(
                            configuration: configuration,
                            deviceToken: registration.deviceToken,
                            environment: registration.environment,
                            title: title,
                            subtitle: nil,
                            body: "Push delivery works.",
                            paneID: nil,
                            workspaceID: nil,
                            workspace: nil,
                            category: nil,
                            notificationIDs: [],
                            threadID: "rai-test",
                            summaryArgument: "rai",
                            summaryArgumentCount: 1,
                            occurredAt: now,
                            badge: nil
                        )
                        return PushDeliveryReport(
                            deviceToken: registration.deviceToken,
                            environment: registration.environment,
                            status: result.status,
                            reason: result.reason
                        )
                    }
                }
                var values: [PushDeliveryReport] = []
                for await report in group { values.append(report) }
                return values.sorted { $0.id < $1.id }
            }
            guard let self else { return }
            self.isSendingTestPush = false
            self.testPushResults = reports
            self.recordDelivery(reports, label: "Test push")
            for report in reports where Self.isDeadToken(report) {
                self.removePushRegistration(deviceToken: report.deviceToken)
            }
        }
        pushOperationTail = operation
    }

    private static func pushTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private static func isDeadToken(_ report: PushDeliveryReport) -> Bool {
        report.status == 410
            || (report.status == 400
                && ["BadDeviceToken", "DeviceTokenNotForTopic", "Unregistered"]
                    .contains(report.reason))
    }

    private func recordDelivery(_ reports: [PushDeliveryReport], label: String = "Push") {
        let delivered = reports.lazy.filter(\.succeeded).count
        lastPushSucceeded = delivered == reports.count && !reports.isEmpty
        lastPushResult = "\(label): \(delivered) of \(reports.count) delivered."
    }

    private func recordNoDelivery(_ message: String) {
        lastPushSucceeded = false
        lastPushResult = message
    }

    private func listenerDidChange(_ state: NWListener.State) {
        switch state {
        case .ready:
            isRunning = true
            statusMessage = nil
        case .failed(let error):
            statusMessage = error.localizedDescription
            isBonjourAdvertised = false
            stop()
        case .cancelled:
            isRunning = false
            isBonjourAdvertised = false
        default:
            break
        }
    }

    private func bonjourRegistrationDidChange(
        _ change: NWListener.ServiceRegistrationChange
    ) {
        switch change {
        case let .add(endpoint):
            registeredBonjourEndpoints.insert(endpoint)
        case let .remove(endpoint):
            registeredBonjourEndpoints.remove(endpoint)
        @unknown default:
            break
        }
        isBonjourAdvertised = !registeredBonjourEndpoints.isEmpty
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
            pushBadgeLedger.removeAll()
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
            guard let existing = observeStreams[clientID]?[paneID] else { return }
            // Full-grid streams mirror the pane's native size — the client's
            // viewport dimensions don't shape them, so a restart would only
            // interrupt a LIVE stream for an identical one. A dead one,
            // though, is a free recovery opportunity.
            if existing.fullGrid && existing.isRunning { return }
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
            // grid (native size), so the seed must drop the pane's rows from
            // the tail — not the client's screenful — or the seam duplicates
            // the rows between viewport height and pane height.
            let seamRows = fullGrid ? (pane.scroll?.viewportRows ?? rows) : rows
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
        guard model.snapshot?.panes.contains(where: { $0.paneID == paneID }) == true else {
            send(.error(message: "Unknown pane \(paneID)."), to: client)
            return
        }

        stopObserveStream(paneID: paneID, for: client)

        // herdr renders the observe frame as a top-left window of the pane's
        // grid, so a stream smaller than the pane silently drops the BOTTOM
        // rows (prompt, cursor) and the RIGHT columns (panning on the phone
        // rubber-bands off a wall where the pane continues). For clients that
        // opted in (fullGrid), frames carry their dimensions and the client
        // scrolls a viewport over the full grid. Legacy clients size their
        // emulator to the view and would garble a stream bigger than it, so
        // they keep view-sized frames.
        //
        // --rows must be PASSED, not omitted. Omitting the size flags does not
        // mirror the pane's native height: observe falls back to a 40-row
        // default, so a 45-row pane lost its bottom 5 rows on every frame —
        // the prompt among them. Measured against a live pane:
        //     no flags            -> height=40, no ❯ row
        //     --rows 45           -> height=45, ❯ row present
        // --cols is still omitted: its default already tracks the pane's width
        // (120 for a 120-column pane), and passing the client's viewport width
        // is what used to clip the right-hand columns.
        let paneRows = model.snapshot?
            .panes.first { $0.paneID == paneID }?
            .scroll?.viewportRows

        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: HerdrCLI.binaryPath)
        process.arguments = fullGrid
            ? ["terminal", "session", "observe", paneID]
                + (paneRows.map { ["--rows", String($0)] } ?? [])
            : [
                "terminal", "session", "observe", paneID,
                "--cols", String(cols), "--rows", String(rows),
            ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        let stream = ObserveStream(
            process: process, stdout: stdout, fullGrid: fullGrid, cols: cols, rows: rows,
            paneRows: paneRows)
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
                // Frames flowing again — the stream is healthy.
                self.observeRestarts[clientID]?[paneID] = 0
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
                guard !stream.isStopping else { return }
                // An observe can die under it (pane resized away, herdr
                // hiccup). The phone can't tell — its viewport just goes
                // silently stale — and full-grid clients no longer restart
                // streams on resize, so recovery is OUR job: restart with
                // backoff, and only surface an error once that keeps failing.
                let attempt = (self.observeRestarts[clientID]?[paneID] ?? 0) + 1
                guard attempt <= 5 else {
                    self.observeRestarts[clientID]?[paneID] = 0
                    self.send(
                        .error(
                            message: "Pane stream \(paneID) exited with status \(process.terminationStatus)."
                        ),
                        to: client
                    )
                    return
                }
                self.observeRestarts[clientID, default: [:]][paneID] = attempt
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 * Double(attempt)) {
                    [weak self, weak client] in
                    guard let self, let client,
                          self.clients[clientID] === client,
                          self.observeStreams[clientID]?[paneID] == nil
                    else { return }
                    self.startObserveStream(
                        paneID: paneID,
                        cols: stream.cols,
                        rows: stream.rows,
                        fullGrid: stream.fullGrid,
                        for: client
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
        pushBadgeLedger.removeDevices { $0.deviceToken == deviceToken }
        pushRegistrations = Set(pushRegistrations.filter { $0.deviceToken != deviceToken })
        pushRegistrations.insert(.init(deviceToken: deviceToken, environment: environment))
        persistPushRegistrations()
    }

    private func removePushRegistration(deviceToken: String) {
        pushBadgeLedger.removeDevices { $0.deviceToken == deviceToken }
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
    /// restarts must preserve it, along with the originally requested size.
    let fullGrid: Bool
    let cols: Int
    let rows: Int
    /// The pane height this stream was started against. A full-grid stream is
    /// rendered at a FIXED row count, so when the pane itself is resized the
    /// stream keeps emitting the old geometry and the client silently loses
    /// (or gains blank) rows. Kept so a snapshot can spot the drift.
    let paneRows: Int?
    private var buffer = Data()
    private(set) var isStopping = false

    var isRunning: Bool { process.isRunning }

    init(
        process: Process, stdout: Pipe, fullGrid: Bool, cols: Int, rows: Int,
        paneRows: Int?
    ) {
        self.process = process
        self.stdout = stdout
        self.fullGrid = fullGrid
        self.cols = cols
        self.rows = rows
        self.paneRows = paneRows
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
