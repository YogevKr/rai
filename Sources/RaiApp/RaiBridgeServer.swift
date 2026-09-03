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

/// Per-device authenticated WebSocket bridge from companion devices to RaiModel's
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
    @Published private(set) var pairingCode: String?
    @Published private(set) var pairingCodeExpiresAt: Date?
    @Published private(set) var pairedDevices: [BridgePairedDevice]
    @Published private(set) var registeredPushDeviceCount = 0
    @Published private(set) var tailscaleHost: String?
    @Published private(set) var tailscaleServeState: TailscaleServeState = .stopped
    @Published private(set) var isBonjourAdvertised = false
    @Published private(set) var testPushResults: [PushDeliveryReport] = []
    @Published private(set) var isSendingTestPush = false
    @Published private(set) var lastPushResult: String?
    @Published private(set) var lastPushSucceeded: Bool?

    let apnsSettings: APNsSettings
    let auditLogURL: URL
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
        guard let pairingCode, let pairingCodeExpiresAt, pairingCodeExpiresAt > Date() else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "rai"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "code", value: pairingCode),
        ]
        if useTLS {
            components.queryItems?.append(URLQueryItem(name: "tls", value: "1"))
        }
        return components.url
    }

    private static let enabledKey = "companionBridgeEnabled"
    private static let pushRegistrationsKey = "companionBridgePushRegistrations"
    private static let credentialMigrationKey = "companionBridgeCredentialMigrationV1"
    private unowned let model: RaiModel
    private let userDefaults: UserDefaults
    private let queue = DispatchQueue(label: "ai.sawmills.rai.bridge")
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: BridgeClient] = [:]
    private let liveConnections = BridgeLiveConnectionRegistry()
    private let credentialStore: BridgeDeviceCredentialStore
    private let auditLogger: BridgeAuditLogger?
    private let clock: () -> Date
    private var pairingExpiryTask: Task<Void, Never>?
    private var observeStreams: [ObjectIdentifier: [String: ObserveStream]] = [:]
    /// Consecutive unexpected observe exits per (client, pane); reset when a
    /// stream produces frames again. Guards the auto-restart loop below.
    private var observeRestarts: [ObjectIdentifier: [String: Int]] = [:]
    private var pushRegistrations: Set<PushRegistration> = []
    /// Atomic delivered alerts per device. A summary counts as one alert.
    /// Opening any client resets this optimistic state, as before.
    private var pushBadgeLedger = PushBadgeLedger<PushRegistration>()
    private let apnsPusher = APNsPusher()
    /// Serializes each device without making one device wait for another.
    private let pushDeliveryQueue: APNsDeliveryQueue
    private let tailscaleServe = TailscaleServeController()
    private var tailscaleTask: Task<Void, Never>?
    private var registeredBonjourEndpoints: Set<NWEndpoint> = []
    var pushPreferencesDidChange: ((String, PushPreferences) -> Void)?

    init(
        model: RaiModel,
        userDefaults: UserDefaults = .standard,
        apnsSettings: APNsSettings? = nil,
        auditLogURL: URL? = nil,
        pushDeliveryQueue: APNsDeliveryQueue? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.model = model
        self.userDefaults = userDefaults
        self.apnsSettings = apnsSettings ?? .shared
        self.pushDeliveryQueue = pushDeliveryQueue ?? APNsDeliveryQueue()
        clock = now
        if !userDefaults.bool(forKey: Self.credentialMigrationKey) {
            userDefaults.removeObject(forKey: "companionBridgePairingToken")
            userDefaults.removeObject(forKey: Self.pushRegistrationsKey)
            userDefaults.set(true, forKey: Self.credentialMigrationKey)
        } else {
            userDefaults.removeObject(forKey: "companionBridgePairingToken")
        }
        let credentialStore = BridgeDeviceCredentialStore(defaults: userDefaults)
        self.credentialStore = credentialStore
        pairingCode = credentialStore.pairingCode?.value
        pairingCodeExpiresAt = credentialStore.pairingCode?.expiresAt
        pairedDevices = credentialStore.devices
        let resolvedAuditURL = auditLogURL ?? BridgeAuditLogger.defaultURL
        self.auditLogURL = resolvedAuditURL
        auditLogger = try? BridgeAuditLogger(fileURL: resolvedAuditURL)
        if let data = userDefaults.data(forKey: Self.pushRegistrationsKey),
           let saved = try? JSONDecoder().decode(Set<PushRegistration>.self, from: data) {
            pushRegistrations = saved
            registeredPushDeviceCount = saved.count
        }
        auditLogger?.setFailureHandler { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.statusMessage = "Bridge audit write failed. Write actions are blocked."
            }
        }
        schedulePairingExpiry()
    }

    func startIfEnabled() {
        if isEnabled {
            start()
        }
    }

    func start() {
        guard listener == nil else { return }
        if credentialStore.validPairingCode() == nil {
            _ = credentialStore.regeneratePairingCode()
        }
        // The store mints its first code in its initializer, so sync here
        // unconditionally: the published code, its expiry timer, and the
        // harness export must reflect whatever code is live at start.
        syncCredentialState()
        schedulePairingExpiry()
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
        liveConnections.removeAll()
        connectedDeviceCount = 0
        isRunning = false
    }

    func stopAndWait() async {
        stop()
        await tailscaleTask?.value
        if let auditLogger {
            _ = await auditLogger.flush()
        }
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

    func regeneratePairingCode() {
        _ = credentialStore.regeneratePairingCode()
        syncCredentialState()
        schedulePairingExpiry()
        if pairingCode == nil {
            statusMessage = "Secure random data is unavailable."
        }
    }

    func revokeDevice(id: String) {
        guard credentialStore.revoke(deviceID: id) else { return }
        let revokedClients = liveConnections.revoke(deviceID: id)
        for clientID in revokedClients {
            stopObserveStreams(for: clientID)
            clients.removeValue(forKey: clientID)
        }
        pushRegistrations = Set(pushRegistrations.filter { $0.deviceID != id })
        persistPushRegistrations()
        if credentialStore.devices.isEmpty {
            credentialStore.invalidatePairingCode()
        }
        syncCredentialState()
        updateConnectedDeviceCount()
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

    func sendPush(
        _ burst: PhonePushBurst,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        let configuration = apnsSettings.configuration
        let registrations = pushRegistrations
        guard !registrations.isEmpty else {
            recordNoDelivery("Push not sent: no registered devices.")
            return
        }
        let plans = registrations.compactMap {
            registration -> (PushRegistration, PhonePushBurst)? in
            guard let allowed = allowedPushBurst(
                burst,
                for: registration,
                now: now,
                calendar: calendar
            ) else { return nil }
            return (registration, allowed)
        }

        guard !plans.isEmpty else {
            lastPushSucceeded = true
            lastPushResult = "Push dropped by device notification preferences."
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
        let deliveries = plans.map { registration, effectiveBurst in
            let deliveryKey = "\(registration.environment):\(registration.deviceToken)"
            return pushDeliveryQueue.enqueue(key: deliveryKey) {
                [weak self] () -> PushDeliveryReport? in
                guard let self else { return nil }
                let deliveryNow = await self.clock()
                guard let deliveryBurst = await self.allowedPushBurst(
                    effectiveBurst,
                    for: registration,
                    now: deliveryNow,
                    calendar: calendar
                ) else { return nil }
                return await self.deliverAlert(
                    configuration: configuration,
                    registration: registration,
                    burst: deliveryBurst,
                    stableIDs: Set(deliveryBurst.notificationIDs)
                )
            }
        }

        Task { [weak self] in
            guard let self else { return }
            var reports: [PushDeliveryReport] = []
            for delivery in deliveries {
                if let report = await delivery.value {
                    reports.append(report)
                }
            }
            if reports.isEmpty {
                self.lastPushSucceeded = true
                self.lastPushResult = "Push dropped by device notification preferences."
            } else {
                self.recordDelivery(reports.sorted { $0.id < $1.id })
            }
        }
    }

    private func allowedPushBurst(
        _ burst: PhonePushBurst,
        for registration: PushRegistration,
        now: Date,
        calendar: Calendar
    ) -> PhonePushBurst? {
        let preferences = registration.deviceID.flatMap { deviceID in
            pairedDevices.first(where: { $0.id == deviceID })?.pushPreferences
        } ?? .default
        return PushPreferenceGate.allowedBurst(
            burst,
            deviceID: registration.deviceID,
            preferences: preferences,
            now: now,
            calendar: calendar
        )
    }

    func deviceIDsSuppressingHeldEvent(
        status: AgentStatus,
        occurredAt: Date,
        calendar: Calendar = .current
    ) -> Set<String> {
        Set(pairedDevices.compactMap { device in
            PushPreferenceGate.suppressesHeldEvent(
                status: status,
                occurredAt: occurredAt,
                preferences: device.pushPreferences,
                calendar: calendar
            ) ? device.id : nil
        })
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
        let retractedBefore = Date()
        let deliveries = registrations.map { registration in
            let deliveryKey = "\(registration.environment):\(registration.deviceToken)"
            return pushDeliveryQueue.enqueue(key: deliveryKey) { [weak self] in
                guard let self else {
                    return RetractionDeliveryReport(
                        pushReport: .init(
                            deviceToken: registration.deviceToken,
                            environment: registration.environment,
                            status: nil,
                            reason: "Bridge stopped"
                        ),
                        acceptedNotificationIDs: []
                    )
                }
                return await self.deliverRetraction(
                    configuration: configuration,
                    registration: registration,
                    identifiers: identifiers,
                    retractedBefore: retractedBefore
                )
            }
        }
        Task { [weak self] in
            guard let self else { return }
            var reports: [RetractionDeliveryReport] = []
            for delivery in deliveries {
                reports.append(await delivery.value)
            }
            let pushReports = reports.map(\.pushReport).sorted { $0.id < $1.id }
            self.recordDelivery(pushReports, label: "Retraction")
        }
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
        let title = "rai test · \(Self.pushTime(now))"
        let deliveries = registrations.map { registration in
            let deliveryKey = "\(registration.environment):\(registration.deviceToken)"
            return pushDeliveryQueue.enqueue(key: deliveryKey) { [weak self] in
                guard let self else {
                    return PushDeliveryReport(
                        deviceToken: registration.deviceToken,
                        environment: registration.environment,
                        status: nil,
                        reason: "Bridge stopped"
                    )
                }
                return await self.deliverTestAlert(
                    configuration: configuration,
                    registration: registration,
                    title: title,
                    now: now
                )
            }
        }
        Task { [weak self] in
            guard let self else { return }
            var reports: [PushDeliveryReport] = []
            for delivery in deliveries {
                reports.append(await delivery.value)
            }
            self.isSendingTestPush = false
            self.testPushResults = reports.sorted { $0.id < $1.id }
            self.recordDelivery(self.testPushResults, label: "Test push")
        }
    }

    private func deliverAlert(
        configuration: APNsConfiguration,
        registration: PushRegistration,
        burst: PhonePushBurst,
        stableIDs: Set<String>
    ) async -> PushDeliveryReport {
        let badge = pushBadgeLedger.proposedBadge(adding: stableIDs, for: registration)
        let result = await apnsPusher.sendAlert(
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
            badge: badge
        )
        let report = PushDeliveryReport(
            deviceToken: registration.deviceToken,
            environment: registration.environment,
            status: result.status,
            reason: result.reason
        )
        if report.succeeded {
            pushBadgeLedger.commitAlert(identifiers: stableIDs, for: registration)
        }
        removeDeadRegistration(for: report)
        return report
    }

    private func deliverRetraction(
        configuration: APNsConfiguration,
        registration: PushRegistration,
        identifiers: [String],
        retractedBefore: Date
    ) async -> RetractionDeliveryReport {
        let result = await apnsPusher.sendRetraction(
            configuration: configuration,
            deviceToken: registration.deviceToken,
            environment: registration.environment,
            notificationIDs: identifiers,
            retractedBefore: retractedBefore
        )
        if !result.acceptedNotificationIDs.isEmpty {
            pushBadgeLedger.commitRetraction(
                identifiers: result.acceptedNotificationIDs,
                for: registration
            )
        }
        let report = PushDeliveryReport(
            deviceToken: registration.deviceToken,
            environment: registration.environment,
            status: result.status,
            reason: result.reason
        )
        removeDeadRegistration(for: report)
        return RetractionDeliveryReport(
            pushReport: report,
            acceptedNotificationIDs: result.acceptedNotificationIDs
        )
    }

    private func deliverTestAlert(
        configuration: APNsConfiguration,
        registration: PushRegistration,
        title: String,
        now: Date
    ) async -> PushDeliveryReport {
        let result = await apnsPusher.sendAlert(
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
        let report = PushDeliveryReport(
            deviceToken: registration.deviceToken,
            environment: registration.environment,
            status: result.status,
            reason: result.reason
        )
        removeDeadRegistration(for: report)
        return report
    }

    private func removeDeadRegistration(for report: PushDeliveryReport) {
        if Self.isDeadToken(report) {
            removePushRegistration(deviceToken: report.deviceToken)
        }
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
                    self.send(.error(
                        message: "Only WebSocket text frames are supported.",
                        code: .invalidRequest,
                        detail: "The bridge accepts WebSocket text frames only."
                    ), to: client)
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
            send(.error(
                message: "Invalid bridge message: \(error.localizedDescription)",
                code: .unknownMessage,
                detail: error.localizedDescription
            ), to: client)
            return
        }

        if !client.isAuthenticated {
            switch message {
            case let .pair(code, clientProtocolVersion, info):
                guard clientProtocolVersion == bridgeProtocolVersion else {
                    reject(
                        client,
                        reason: "Re-pair required",
                        code: .protocolMismatch,
                        detail: "Phone protocol \(clientProtocolVersion); Mac protocol \(bridgeProtocolVersion)."
                    )
                    return
                }
                switch credentialStore.exchange(code: code, client: info) {
                case let .success(result):
                    syncCredentialState()
                    send(
                        .paired(
                            token: result.token,
                            protocolVersion: bridgeProtocolVersion,
                            sessionName: model.currentSessionName
                        ),
                        to: client
                    )
                case .failure(.invalidOrExpired):
                    syncCredentialState()
                    reject(
                        client,
                        reason: "Pairing code invalid or expired",
                        code: .pairingCodeInvalid
                    )
                case .failure(.entropyUnavailable):
                    statusMessage = "Secure random data is unavailable."
                    reject(client, reason: "Pairing is unavailable", code: .operationFailed)
                }
            case let .hello(token, info):
                guard let device = credentialStore.authenticate(token: token) else {
                    reject(client, reason: "Re-pair required", code: .repairRequired)
                    return
                }
                syncCredentialState()
                if credentialStore.pairingCode == nil {
                    pairingExpiryTask?.cancel()
                }
                authenticate(client, as: device, info: info)
                send(
                    .welcome(
                        protocolVersion: bridgeProtocolVersion,
                        sessionName: model.currentSessionName
                    ),
                    to: client
                )
                send(.pushPrefsState(device.pushPreferences.effective(at: Date())), to: client)
            default:
                reject(
                    client,
                    reason: "Pair or hello must be the first message",
                    code: .repairRequired
                )
            }
            return
        }

        if let auditEvent = BridgeAuditEvent(message) {
            guard let auditLogger else {
                statusMessage = "Bridge audit log is unavailable. Write actions are blocked."
                send(.error(
                    message: "Bridge audit log is unavailable.",
                    code: .auditUnavailable,
                    detail: "The Mac could not open the audit log."
                ), to: client)
                return
            }
            guard auditLogger.enqueue(
                deviceID: client.deviceID ?? "unknown",
                deviceLabel: client.deviceLabel ?? "Unknown device",
                event: auditEvent
            ) else {
                statusMessage = "Bridge audit write failed. Write actions are blocked."
                send(.error(
                    message: "Bridge audit write failed.",
                    code: .auditUnavailable,
                    detail: "The Mac could not append the audit event."
                ), to: client)
                return
            }
        }

        switch message {
        case .subscribe:
            client.isSubscribed = true
            if let snapshot = model.snapshot {
                send(.snapshot(snapshot.addingBeacons(model.beaconsForBridge)), to: client)
            } else {
                send(.error(
                    message: "Herdr is not connected.",
                    code: .herdMissing,
                    detail: "The Mac bridge has no active herdr snapshot."
                ), to: client)
            }
        case let .attachStream(paneID, cols, rows, fullGrid):
            guard client.isSubscribed else {
                send(.error(
                    message: "Subscribe before attaching a pane stream.",
                    code: .invalidRequest,
                    detail: "The client did not subscribe."
                ), to: client)
                return
            }
            guard cols > 0, rows > 0 else {
                send(.error(
                    message: "Pane dimensions must be positive.",
                    code: .invalidRequest,
                    detail: "Columns and rows must exceed zero."
                ), to: client)
                return
            }
            startObserveStream(
                paneID: paneID, cols: cols, rows: rows, fullGrid: fullGrid, for: client)
        case let .detachStream(paneID):
            stopObserveStream(paneID: paneID, for: client)
        case let .input(paneID, bytesBase64):
            guard let data = Data(base64Encoded: bytesBase64) else {
                send(.error(
                    message: "input bytesBase64 is invalid.",
                    code: .invalidRequest,
                    detail: "Input is not valid Base64 data."
                ), to: client)
                return
            }
            await perform(for: client) {
                try await self.model.client.sendInput(paneID: paneID, bytes: [UInt8](data))
            }
        case let .sendImage(paneID, bytesBase64, filename):
            guard let data = Data(base64Encoded: bytesBase64), !data.isEmpty else {
                send(.error(
                    message: "sendImage bytesBase64 is invalid.",
                    code: .invalidRequest,
                    detail: "Image input is empty or invalid Base64 data."
                ), to: client)
                return
            }
            guard data.count <= 5 * 1_024 * 1_024 else {
                send(.error(
                    message: "Images must be 5 MB or smaller.",
                    code: .invalidRequest,
                    detail: "The decoded image exceeds 5242880 bytes."
                ), to: client)
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
        case let .pushPrefs(preferences):
            guard let deviceID = client.deviceID,
                  let device = credentialStore.updatePushPreferences(
                    preferences.effective(at: Date()),
                    deviceID: deviceID
                  ) else {
                send(.error(
                    message: "Re-pair required.",
                    code: .repairRequired,
                    detail: "The paired device record is missing."
                ), to: client)
                return
            }
            syncCredentialState()
            pushPreferencesDidChange?(deviceID, device.pushPreferences)
            send(.pushPrefsState(device.pushPreferences), to: client)
        case let .selectPane(paneID):
            guard model.snapshot?.panes.contains(where: { $0.paneID == paneID }) == true else {
                send(.error(
                    message: "Unknown pane \(paneID).",
                    code: .paneGone,
                    detail: paneID
                ), to: client)
                return
            }
            model.select(paneID: paneID, focusInHerdr: true)
        case let .resizePane(paneID, cols, rows):
            guard cols > 0, rows > 0 else {
                send(.error(
                    message: "Pane dimensions must be positive.",
                    code: .invalidRequest,
                    detail: "Columns and rows must exceed zero."
                ), to: client)
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
                send(.error(
                    message: "Unknown workspace \(workspaceID).",
                    code: .operationFailed,
                    detail: workspaceID
                ), to: client)
                return
            }
            // "terminal" is a plain shell pane, not an agent — routed through
            // the same message so older phones and Macs stay compatible.
            if agent == "terminal" {
                guard await model.createTerminalFromBridge(workspaceID: workspaceID, cwd: cwd)
                else {
                    send(.error(
                        message: "Could not launch \(agent).",
                        code: .operationFailed,
                        detail: agent
                    ), to: client)
                    return
                }
                return
            }
            guard let kind = AgentLaunchKind(rawValue: agent) else {
                send(.error(
                    message: "Agent must be claude or codex.",
                    code: .invalidRequest,
                    detail: agent
                ), to: client)
                return
            }
            guard await model.launchAgentFromBridge(kind, workspaceID: workspaceID, cwd: cwd)
            else {
                send(.error(
                    message: "Could not launch \(agent).",
                    code: .operationFailed,
                    detail: agent
                ), to: client)
                return
            }
        case let .renamePane(paneID, label):
            guard await model.renamePaneFromBridge(paneID: paneID, label: label) else {
                send(.error(
                    message: "Could not rename pane \(paneID).",
                    code: .paneGone,
                    detail: paneID
                ), to: client)
                return
            }
        case let .renameTab(tabID, label):
            guard await model.renameTabFromBridge(tabID: tabID, label: label) else {
                send(.error(
                    message: "Could not rename tab \(tabID).",
                    code: .operationFailed,
                    detail: tabID
                ), to: client)
                return
            }
        case let .closePane(paneID):
            guard await model.closePaneFromBridge(paneID: paneID) else {
                send(.error(
                    message: "Could not close pane \(paneID).",
                    code: .paneGone,
                    detail: paneID
                ), to: client)
                return
            }
        case let .closeTab(tabID):
            guard await model.closeTabFromBridge(tabID: tabID) else {
                send(.error(
                    message: "Could not close tab \(tabID).",
                    code: .operationFailed,
                    detail: tabID
                ), to: client)
                return
            }
        case let .sendKeys(paneID, keys):
            guard !keys.isEmpty, keys.count <= 8 else {
                send(.error(
                    message: "sendKeys takes 1-8 keys.",
                    code: .invalidRequest,
                    detail: "Received \(keys.count) keys."
                ), to: client)
                return
            }
            await perform(for: client) {
                try await self.model.client.sendKeys(paneID: paneID, keys: keys)
            }
        case let .readScrollback(paneID, lines, rows, fullGrid):
            guard let pane = model.snapshot?.panes.first(where: { $0.paneID == paneID }) else {
                send(.error(
                    message: "Unknown pane \(paneID).",
                    code: .paneGone,
                    detail: paneID
                ), to: client)
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
                send(.error(
                    message: "Could not read scrollback for \(paneID).",
                    code: .scrollbackUnavailable,
                    detail: paneID
                ), to: client)
                return
            }
            send(
                .scrollback(paneID: paneID, bytesBase64: payload.base64EncodedString()),
                to: client
            )
        case let .registerPush(deviceToken, environment):
            guard environment == "sandbox" || environment == "production" else {
                send(.error(
                    message: "Push environment must be sandbox or production.",
                    code: .invalidRequest,
                    detail: environment
                ), to: client)
                return
            }
            let normalizedToken = deviceToken.lowercased()
            guard normalizedToken.count == 64,
                  normalizedToken.allSatisfy(\.isHexDigit)
            else {
                send(.error(
                    message: "Push device token must be 64 hexadecimal characters.",
                    code: .invalidRequest,
                    detail: "The token format is invalid."
                ), to: client)
                return
            }
            registerPush(
                deviceToken: normalizedToken,
                environment: environment,
                deviceID: client.deviceID
            )
        case let .unregisterPush(deviceToken):
            removePushRegistration(deviceToken: deviceToken.lowercased())
        case .pair, .hello:
            send(.error(
                message: "Connection is already authenticated.",
                code: .invalidRequest,
                detail: "Pair and hello are handshake messages."
            ), to: client)
        case .paired, .welcome, .authFailed, .snapshot, .event, .paneFrame, .scrollback, .error,
             .backgroundWork, .sessions, .pushPrefsState:
            send(.error(
                message: "Server-to-client message received from client.",
                code: .unknownMessage,
                detail: "The message direction is invalid."
            ), to: client)
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
            send(.error(
                message: "Unknown pane \(paneID).",
                code: .paneGone,
                detail: paneID
            ), to: client)
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
                            message: "Pane stream \(paneID) exited with status \(process.terminationStatus).",
                            code: .paneBusy,
                            detail: "Observe exited after five restart attempts."
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
                .error(
                    message: "Unable to start pane stream \(paneID): \(error.localizedDescription)",
                    code: .streamUnavailable,
                    detail: error.localizedDescription
                ),
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
            let code = Self.errorCode(for: error)
            send(.error(
                message: error.localizedDescription,
                code: code,
                detail: String(reflecting: error)
            ), to: client)
        }
    }

    private static func errorCode(for error: Error) -> BridgeErrorCode {
        guard case let HerdrClientError.remote(code, _) = error else {
            return .operationFailed
        }
        if code.localizedCaseInsensitiveContains("busy") {
            return .paneBusy
        }
        if code.localizedCaseInsensitiveContains("pane"),
           code.localizedCaseInsensitiveContains("not") {
            return .paneGone
        }
        return .operationFailed
    }

    private func reject(
        _ client: BridgeClient,
        reason: String,
        code: BridgeErrorCode,
        detail: String? = nil
    ) {
        send(.authFailed(reason: reason, code: code, detail: detail ?? reason), to: client) {
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
        liveConnections.remove(id: id)
        updateConnectedDeviceCount()
    }

    private func updateConnectedDeviceCount() {
        connectedDeviceCount = liveConnections.connectedDeviceCount
    }

    private func registerPush(deviceToken: String, environment: String, deviceID: String?) {
        pushBadgeLedger.removeDevices { $0.deviceToken == deviceToken }
        pushRegistrations = Set(pushRegistrations.filter { $0.deviceToken != deviceToken })
        pushRegistrations.insert(
            .init(deviceToken: deviceToken, environment: environment, deviceID: deviceID)
        )
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

    private func authenticate(
        _ client: BridgeClient,
        as device: BridgePairedDevice,
        info: ClientInfo
    ) {
        client.isAuthenticated = true
        client.info = info
        client.deviceID = device.id
        client.deviceLabel = device.label
        pushBadgeLedger.removeAll()
        let id = ObjectIdentifier(client.connection)
        liveConnections.register(id: id, deviceID: device.id) { [weak self, weak client] in
            guard let self, let client else { return }
            self.reject(client, reason: "Re-pair required", code: .repairRequired)
        }
        updateConnectedDeviceCount()
    }

    private func syncCredentialState() {
        let active = credentialStore.validPairingCode()
        pairingCode = active?.value
        pairingCodeExpiresAt = active?.expiresAt
        pairedDevices = credentialStore.devices
        if let exportURL = PairingCodeExport.configuredURL {
            try? PairingCodeExport.write(code: active?.value, to: exportURL)
        }
    }

    private func schedulePairingExpiry() {
        pairingExpiryTask?.cancel()
        guard let expiry = credentialStore.pairingCode?.expiresAt else { return }
        pairingExpiryTask = Task { [weak self] in
            let delay = max(0, expiry.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.syncCredentialState()
        }
    }
}

/// One APNs registration. Identity is the token + environment pair: the
/// paired-device id is metadata, so a ledger key rebuilt from a delivery
/// report (which carries no device id) still finds the registration.
private struct PushRegistration: Codable, Hashable, Sendable {
    let deviceToken: String
    let environment: String
    let deviceID: String?

    init(deviceToken: String, environment: String, deviceID: String? = nil) {
        self.deviceToken = deviceToken
        self.environment = environment
        self.deviceID = deviceID
    }

    static func == (lhs: PushRegistration, rhs: PushRegistration) -> Bool {
        lhs.deviceToken == rhs.deviceToken && lhs.environment == rhs.environment
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(deviceToken)
        hasher.combine(environment)
    }
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
    var deviceID: String?
    var deviceLabel: String?

    init(connection: NWConnection) {
        self.connection = connection
    }
}
