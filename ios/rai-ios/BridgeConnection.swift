import Combine
import Foundation
import Network
import RaiCore
import UIKit

enum ConnectionRecoveryAction: Equatable {
    case reconnect
    case pairAgain

    var title: String {
        switch self {
        case .reconnect: "Reconnect"
        case .pairAgain: "Pair Again"
        }
    }
}

enum BridgeErrorDestination: Equatable {
    case reconnect
    case pairAgain
    case updateRequired
    case actionError
    case ignore
}

enum BridgeErrorPhase: Hashable {
    case authentication
    case operation
}

enum BridgeErrorPolicy {
    private static let operationDestinations: [BridgeErrorCode: BridgeErrorDestination] = [
        .herdMissing: .reconnect,
        .paneGone: .actionError,
        .paneBusy: .actionError,
        .auditUnavailable: .actionError,
        .repairRequired: .pairAgain,
        .pairingCodeInvalid: .pairAgain,
        .protocolMismatch: .reconnect,
        .unknownMessage: .actionError,
        .invalidRequest: .actionError,
        .operationFailed: .actionError,
        .streamUnavailable: .actionError,
        .scrollbackUnavailable: .ignore,
    ]

    private static let authenticationDestinations: [BridgeErrorCode: BridgeErrorDestination] = [
        .herdMissing: .reconnect,
        .paneGone: .reconnect,
        .paneBusy: .reconnect,
        .auditUnavailable: .reconnect,
        .repairRequired: .pairAgain,
        .pairingCodeInvalid: .pairAgain,
        .protocolMismatch: .updateRequired,
        .unknownMessage: .reconnect,
        .invalidRequest: .reconnect,
        .operationFailed: .reconnect,
        .streamUnavailable: .reconnect,
        .scrollbackUnavailable: .reconnect,
    ]

    static let destinations: [BridgeErrorPhase: [BridgeErrorCode: BridgeErrorDestination]] = [
        .authentication: authenticationDestinations,
        .operation: operationDestinations,
    ]

    static func destination(
        for code: BridgeErrorCode,
        phase: BridgeErrorPhase
    ) -> BridgeErrorDestination {
        destinations[phase]?[code] ?? .actionError
    }

    static func authenticationProseDestination(_ message: String) -> BridgeErrorDestination {
        let normalized = message.lowercased()
        if normalized.contains("protocol") || normalized.contains("version mismatch") {
            return .updateRequired
        }
        if normalized.contains("re-pair")
            || normalized.contains("repair")
            || normalized.contains("pairing code")
            || normalized.contains("invalid token")
            || normalized.contains("revoked")
            || normalized.contains("unknown device")
            || (normalized.contains("credential") && normalized.contains("missing")) {
            return .pairAgain
        }
        return .reconnect
    }
}

struct ConnectionDiagnosis: Equatable {
    let message: String
    let rawDetails: String
    let action: ConnectionRecoveryAction

    static func transport(_ error: Error, host: String) -> ConnectionDiagnosis {
        let rawDetails = String(reflecting: error)

        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotFindHost, .dnsLookupFailed:
                return hostMissing(host, rawDetails: rawDetails)
            case .cannotConnectToHost:
                return macNotListening(rawDetails: rawDetails)
            case .timedOut, .notConnectedToInternet, .cannotLoadFromNetwork:
                return noRoute(rawDetails: rawDetails)
            case .networkConnectionLost:
                return connectionLost(host: host, rawDetails: rawDetails)
            case .secureConnectionFailed, .serverCertificateHasBadDate,
                 .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid, .clientCertificateRejected,
                 .clientCertificateRequired:
                return tls(rawDetails: rawDetails)
            default:
                break
            }
        }

        if let networkError = error as? NWError {
            switch networkError {
            case .dns:
                return hostMissing(host, rawDetails: rawDetails)
            case let .posix(code):
                switch code {
                case .ECONNREFUSED, .ECONNRESET:
                    return macNotListening(rawDetails: rawDetails)
                case .ECONNABORTED, .EPIPE:
                    return connectionLost(host: host, rawDetails: rawDetails)
                case .ETIMEDOUT, .ENETUNREACH, .EHOSTUNREACH, .ENETDOWN, .EHOSTDOWN:
                    return noRoute(rawDetails: rawDetails)
                default:
                    break
                }
            case .tls:
                return tls(rawDetails: rawDetails)
            default:
                break
            }
        }

        return ConnectionDiagnosis(
            message: "Connection to \(host) failed",
            rawDetails: rawDetails,
            action: .reconnect
        )
    }

    static func helloRejected(reason: String) -> ConnectionDiagnosis {
        ConnectionDiagnosis(
            message: "Pairing was rejected by the Mac",
            rawDetails: reason,
            action: .pairAgain
        )
    }

    static func coded(
        _ code: BridgeErrorCode,
        message: String,
        detail: String?,
        host: String
    ) -> ConnectionDiagnosis {
        let rawDetails = detail ?? message
        switch code {
        case .herdMissing:
            return herdMissing(rawDetails: rawDetails)
        case .repairRequired, .pairingCodeInvalid:
            return ConnectionDiagnosis(
                message: code == .pairingCodeInvalid
                    ? "The pairing code is invalid or expired"
                    : "Pairing was rejected by the Mac",
                rawDetails: rawDetails,
                action: .pairAgain
            )
        case .protocolMismatch:
            return ConnectionDiagnosis(
                message: "Rai versions don't match — update Rai on the Mac or iPhone",
                rawDetails: rawDetails,
                action: .reconnect
            )
        default:
            return serverError(message, host: host)
        }
    }

    static func invalidPairingReply() -> ConnectionDiagnosis {
        ConnectionDiagnosis(
            message: "The Mac sent an invalid pairing reply",
            rawDetails: "Invalid pairing reply",
            action: .pairAgain
        )
    }

    static func macPredatesPairing() -> ConnectionDiagnosis {
        ConnectionDiagnosis(
            message: "Update Rai on the Mac — it predates device pairing",
            rawDetails: "The Mac rejected the pair message as an invalid bridge message",
            action: .pairAgain
        )
    }

    static func protocolMismatch(_ version: Int) -> ConnectionDiagnosis {
        ConnectionDiagnosis(
            message: "Rai versions don't match — update Rai on the Mac or iPhone",
            rawDetails: "Unsupported bridge protocol \(version)",
            action: .reconnect
        )
    }

    static func herdMissing(rawDetails: String) -> ConnectionDiagnosis {
        ConnectionDiagnosis(
            message: "herdr isn't running on the Mac",
            rawDetails: rawDetails,
            action: .reconnect
        )
    }

    static func invalidAddress(host: String) -> ConnectionDiagnosis {
        ConnectionDiagnosis(
            message: "The address for \(host) isn't valid",
            rawDetails: "Invalid bridge address",
            action: .pairAgain
        )
    }

    static func serverError(_ message: String, host: String) -> ConnectionDiagnosis {
        ConnectionDiagnosis(
            message: "Connection to \(host) failed",
            rawDetails: message,
            action: .reconnect
        )
    }

    static func bridgeError(_ message: String, host: String) -> ConnectionDiagnosis {
        let normalized = message.lowercased()
        if normalized == "herdr is not connected."
            || normalized == "herdr is unavailable." {
            return herdMissing(rawDetails: message)
        }
        return serverError(message, host: host)
    }

    private static func hostMissing(
        _ host: String,
        rawDetails: String
    ) -> ConnectionDiagnosis {
        ConnectionDiagnosis(
            message: "Can't find \(host) on this network",
            rawDetails: rawDetails,
            action: .reconnect
        )
    }

    private static func macNotListening(rawDetails: String) -> ConnectionDiagnosis {
        ConnectionDiagnosis(
            message: "Rai on the Mac isn't listening — is Rai running with the bridge on?",
            rawDetails: rawDetails,
            action: .reconnect
        )
    }

    private static func noRoute(rawDetails: String) -> ConnectionDiagnosis {
        ConnectionDiagnosis(
            message: "No route to the Mac — same Wi-Fi, or Tailscale on?",
            rawDetails: rawDetails,
            action: .reconnect
        )
    }

    private static func connectionLost(
        host: String,
        rawDetails: String
    ) -> ConnectionDiagnosis {
        ConnectionDiagnosis(
            message: "Connection to \(host) was lost",
            rawDetails: rawDetails,
            action: .reconnect
        )
    }

    private static func tls(rawDetails: String) -> ConnectionDiagnosis {
        ConnectionDiagnosis(
            message: "TLS failed — check Tailscale Serve on the Mac",
            rawDetails: rawDetails,
            action: .reconnect
        )
    }
}

enum SnapshotFreshness {
    static func lastSeen(at date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return "last seen \(formatter.string(from: date))"
    }

    static func syncedAgo(since date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "synced \(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "synced \(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "synced \(hours)h ago" }
        return "synced \(hours / 24)d ago"
    }
}

enum PushPreferencesTimeZoneSync {
    static func applyingCurrentZone(
        to preferences: PushPreferences,
        timeZone: TimeZone
    ) -> PushPreferences {
        guard var dnd = preferences.dnd else { return preferences }
        dnd.timeZoneIdentifier = timeZone.identifier
        var updated = preferences
        updated.dnd = dnd
        return updated
    }
}

private struct StoredPendingPushPreferences: Codable {
    let preferences: PushPreferences
}

/// Grid dimensions of a streamed pane frame — the size the emulator must be
/// for the frame's cell-addressed paints to land where herdr rendered them.
struct PaneGridSize: Equatable {
    let cols: Int
    let rows: Int
}

enum ComposedLineSendResult: Equatable {
    case accepted
    case queued
    case refused
}

private struct PasswordPromptGridEvidence {
    let generation: UInt64
    let grid: String
}

enum DecisionWaiterRouting {
    static func requestIDs(
        waiterSocketIDs: [String: ObjectIdentifier],
        failingSocketID: ObjectIdentifier
    ) -> [String] {
        waiterSocketIDs.compactMap { requestID, socketID in
            socketID == failingSocketID ? requestID : nil
        }
    }
}

enum PushRegistrationPlan {
    static func messages(
        deviceToken: String,
        environment: String,
        availability: PermissionDecisionAvailability
    ) -> [BridgeMessage] {
        [
            .registerPush(deviceToken: deviceToken, environment: environment),
            .decisionAvailability(
                available: availability.available,
                pushAuthorized: availability.notificationAuthorized
            ),
        ]
    }
}
@MainActor
final class BridgeConnection: ObservableObject {
    private struct DecisionWaiter {
        let socket: URLSessionWebSocketTask
        let continuation: CheckedContinuation<Bool, Never>
    }
    enum Status: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(ConnectionDiagnosis)

        var label: String {
            switch self {
            case .disconnected: "Disconnected"
            case .connecting: "Connecting…"
            case .connected: "Connected"
            case let .failed(diagnosis): diagnosis.message
            }
        }

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }

        var diagnosis: ConnectionDiagnosis? {
            if case let .failed(diagnosis) = self { return diagnosis }
            return nil
        }
    }

    @Published private(set) var status: Status = .disconnected
    @Published private(set) var snapshot: SessionSnapshot?
    @Published private(set) var isShowingCachedSnapshot = false
    @Published private(set) var lastSnapshotAt: Date?
    @Published private(set) var actionError: String?
    @Published private(set) var sessionName: String?
    @Published private(set) var sessions: [BridgeSessionInfo] = []
    @Published private(set) var pushPreferences: PushPreferences = .default
    @Published private(set) var pendingPushPreferences: PushPreferences?
    @Published private(set) var supportsPushPreferences = false
    /// Composed lines waiting for a connection, oldest first. Surfaced so the
    /// compose bar can say a line is held rather than silently swallowing it.
    @Published private(set) var outbox: [QueuedLine] = []
    @Published private(set) var pendingComposedDrafts: [String: String] = [:]
    var didConnect: (() -> Void)?
    var didPair: ((Pairing) -> Void)?
    var didReceiveSnapshot: ((SessionSnapshot, Date) -> Void)?
    var didReceiveBackgroundWork: (([PaneBackgroundWork]) -> Void)?

    var requiresRepair: Bool {
        status.diagnosis?.action == .pairAgain
    }

    var hasPendingReconnect: Bool {
        reconnectTask != nil
    }

    var pushPreferencesSyncStatus: String? {
        pendingPushPreferences == nil ? nil : "Pending"
    }

    var shouldShowEmptyHerd: Bool {
        status.isConnected
            && snapshot?.panes.isEmpty == true
            && !isShowingCachedSnapshot
    }

    var host: String {
        pairing?.host ?? invitation?.host ?? "Mac"
    }

    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var pairing: Pairing?
    private var invitation: PairingInvitation?
    private var reconnectAttempt = 0
    private var shouldReconnect = false
    private let currentTimeZone: () -> TimeZone
    private let userDefaults: UserDefaults
    private let messageSender: ((BridgeMessage) async throws -> Void)?
    private let now: () -> Date
    private let replyFrameWaitIterations: Int
    private var timeZoneObserver: AnyCancellable?
    private static let pendingPushPreferencesKey = "bridge.pendingPushPreferences"

    init(
        notificationCenter: NotificationCenter = .default,
        currentTimeZone: @escaping () -> TimeZone = { .current },
        userDefaults: UserDefaults = .standard,
        messageSender: ((BridgeMessage) async throws -> Void)? = nil,
        now: @escaping () -> Date = Date.init,
        replyFrameWaitIterations: Int = 50
    ) {
        self.currentTimeZone = currentTimeZone
        self.userDefaults = userDefaults
        self.messageSender = messageSender
        self.now = now
        self.replyFrameWaitIterations = replyFrameWaitIterations
        if let data = userDefaults.data(forKey: Self.pendingPushPreferencesKey),
           let stored = try? JSONDecoder().decode(
               StoredPendingPushPreferences.self,
               from: data
           ) {
            pendingPushPreferences = stored.preferences
        }
        timeZoneObserver = notificationCenter.publisher(for: .NSSystemTimeZoneDidChange)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.synchronizePushPreferencesTimeZone()
                }
            }
    }
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private(set) var connectionGeneration: UInt64 = 0
    private var connectionGenerationHandlers: [UUID: (UInt64) -> Void] = [:]
    private var paneFrameHandlers: [String: [UUID: (Data, Bool, PaneGridSize?) -> Void]] = [:]
    private var paneScrollbackHandlers: [String: [UUID: (Data) -> Void]] = [:]
    private var latestGridByPaneID: [String: PasswordPromptGridEvidence] = [:]
    private let passwordPromptGridReader = PasswordPromptGridReader()
    // A seed can land before the terminal view has registered its handler
    // (openPane fires from onAppear, which can precede makeUIView). Hold the
    // payload and deliver it on registration instead of dropping it.
    private var pendingScrollback: [String: Data] = [:]
    private var desiredStreams: [String: (cols: Int, rows: Int)] = [:]
    // Panes whose scrollback seed actually arrived. Tracked separately from
    // desiredStreams so a seed lost to a dropped connection (opening a pane
    // while reconnecting is routine on a phone) is retried on the next
    // welcome instead of being skipped forever.
    private var seededPanes: Set<String> = []
    private var decisionBeaconReceivedAt: [String: Date] = [:]
    private var decisionWaiters: [String: DecisionWaiter] = [:]
    private var notificationAuthorizationGranted = false
    private var appIsForeground = false

    func updateDecisionAvailability(
        notificationAuthorized: Bool,
        isForeground: Bool
    ) {
        let previous = decisionAvailability
        notificationAuthorizationGranted = notificationAuthorized
        appIsForeground = isForeground
        let current = decisionAvailability
        guard current != previous, status.isConnected else { return }
        Task {
            do {
                try await send(
                    .decisionAvailability(
                        available: current.available,
                        pushAuthorized: current.notificationAuthorized
                    )
                )
            } catch {
                handleSocketFailure(error)
            }
        }
    }

    private var decisionAvailability: PermissionDecisionAvailability {
        PermissionDecisionAvailability(
            notificationAuthorized: notificationAuthorizationGranted,
            appIsForeground: appIsForeground
        )
    }

    func connect(to pairing: Pairing) {
        let changesMac = self.pairing.map { $0 != pairing } ?? false
        disconnect(clearPairing: false, clearSnapshot: changesMac)
        if changesMac {
            clearPendingPushPreferences()
            supportsPushPreferences = false
        }
        self.pairing = pairing
        invitation = nil
        shouldReconnect = true
        reconnectAttempt = 0
        openSocket()
    }

    func pair(using invitation: PairingInvitation) {
        // A code for another Mac must not keep showing this Mac's herd.
        let changesMac = pairing.map {
            $0.host != invitation.host || $0.port != invitation.port
        } ?? true
        disconnect(clearPairing: false, clearSnapshot: changesMac)
        clearPendingPushPreferences()
        supportsPushPreferences = false
        pairing = nil
        self.invitation = invitation
        shouldReconnect = true
        reconnectAttempt = 0
        openSocket()
    }

    func disconnect() {
        disconnect(clearPairing: true, clearSnapshot: true)
    }

    func retryNow() {
        guard pairing != nil || invitation != nil else { return }
        advanceConnectionGeneration()
        task?.cancel(with: .goingAway, reason: nil)
        receiveTask?.cancel()
        reconnectTask?.cancel()
        reconnectAttempt = 0
        shouldReconnect = true
        status = .connecting
        openSocket()
    }

    func restoreCachedSnapshot(_ cached: CachedHerdSnapshot) {
        snapshot = cached.snapshot
        lastSnapshotAt = cached.savedAt
        isShowingCachedSnapshot = true
    }

    func replaceWithLiveSnapshot(_ snapshot: SessionSnapshot, receivedAt: Date = Date()) {
        let activeRequestIDs: Set<String> = Set(snapshot.panes.compactMap { pane -> String? in
            guard pane.beacon?.awaitsDecision == true else { return nil }
            return pane.beacon?.requestID
        })
        decisionBeaconReceivedAt = decisionBeaconReceivedAt.filter {
            activeRequestIDs.contains($0.key)
        }
        for requestID in activeRequestIDs where decisionBeaconReceivedAt[requestID] == nil {
            decisionBeaconReceivedAt[requestID] = receivedAt
        }
        self.snapshot = snapshot
        lastSnapshotAt = receivedAt
        isShowingCachedSnapshot = false
        status = .connected
        didReceiveSnapshot?(snapshot, receivedAt)
    }

    func receivedAt(for beacon: AgentBeacon) -> Date {
        beacon.requestID.flatMap { decisionBeaconReceivedAt[$0] }
            ?? lastSnapshotAt
            ?? Date()
    }

    func refreshSnapshot() async {
        guard status.isConnected else {
            retryNow()
            return
        }
        do {
            try await send(.subscribe)
        } catch {
            handleSocketFailure(error)
        }
    }

    func clearActionError() {
        actionError = nil
    }

    func showActionError(_ message: String) {
        actionError = message
    }

    func setPushPreferences(_ preferences: PushPreferences) {
        let preferences = PushPreferencesTimeZoneSync.applyingCurrentZone(
            to: preferences,
            timeZone: currentTimeZone()
        )
        storePendingPushPreferences(preferences)
        guard status.isConnected, supportsPushPreferences else { return }
        Task {
            do {
                try await send(.pushPrefs(preferences))
            } catch {
                handleSocketFailure(error)
            }
        }
    }

    func openPane(paneID: String, cols: Int = 80, rows: Int = 24) {
        let needsSeed = !seededPanes.contains(paneID)
        if desiredStreams[paneID] == nil {
            desiredStreams[paneID] = (cols, rows)
        }
        Task {
            do {
                try await send(.selectPane(paneID: paneID))
                try await send(.focusPane(paneID: paneID))
                // Read the size at send time, not at entry: the terminal's
                // layout often lands (and updates desiredStreams) between
                // openPane and this send, and the server drops resizes for
                // panes with no active stream — attaching with a stale size
                // would leave the stream permanently smaller than the view.
                let size = desiredStreams[paneID] ?? (cols, rows)
                if needsSeed {
                    // Sent before attachStream: the server handles messages in
                    // order, so history arrives before the first full frame.
                    try await send(
                        .readScrollback(
                            paneID: paneID, lines: 1000, rows: size.rows, fullGrid: true)
                    )
                }
                // fullGrid: the stream is never smaller than the pane's grid;
                // frames carry their dimensions and the emulator pins to them,
                // scrolling a viewport instead of clipping the pane's bottom.
                try await send(
                    .attachStream(
                        paneID: paneID, cols: size.cols, rows: size.rows, fullGrid: true)
                )
            } catch {
                handleSocketFailure(error)
            }
        }
    }

    func detachPane(paneID: String) {
        desiredStreams.removeValue(forKey: paneID)
        latestGridByPaneID.removeValue(forKey: paneID)
        passwordPromptGridReader.remove(paneID)
        // Re-opening the pane later should seed fresh history again.
        seededPanes.remove(paneID)
        Task {
            do {
                try await send(.detachStream(paneID: paneID))
            } catch {
                handleSocketFailure(error)
            }
        }
    }

    func launchAgent(workspaceID: String?, agent: String, cwd: String? = nil) {
        sendAction(.launchAgent(workspaceID: workspaceID, agent: agent, cwd: cwd))
    }

    func renamePane(paneID: String, label: String) {
        sendAction(.renamePane(paneID: paneID, label: label))
    }

    func renameTab(tabID: String, label: String) {
        sendAction(.renameTab(tabID: tabID, label: label))
    }

    func closePane(paneID: String) {
        sendAction(.closePane(paneID: paneID))
    }

    func closeTab(tabID: String) {
        sendAction(.closeTab(tabID: tabID))
    }

    func renameWorkspace(workspaceID: String, label: String) {
        sendAction(.renameWorkspace(workspaceID: workspaceID, label: label))
    }

    func closeWorkspace(workspaceID: String) {
        sendAction(.closeWorkspace(workspaceID: workspaceID))
    }

    func broadcastInput(tabID: String, text: String) {
        sendAction(.broadcastInput(tabID: tabID, text: text))
    }

    private func sendAction(_ message: BridgeMessage) {
        Task {
            do {
                try await send(message)
            } catch {
                handleSocketFailure(error)
            }
        }
    }

    func resizePane(paneID: String, cols: Int, rows: Int) {
        guard cols > 0, rows > 0,
              desiredStreams[paneID]?.cols != cols || desiredStreams[paneID]?.rows != rows
        else { return }
        desiredStreams[paneID] = (cols, rows)
        Task {
            do {
                try await send(.resizePane(paneID: paneID, cols: cols, rows: rows))
            } catch {
                handleSocketFailure(error)
            }
        }
    }

    func addPaneFrameHandler(
        for paneID: String,
        handler: @escaping (Data, Bool, PaneGridSize?) -> Void
    ) -> UUID {
        let id = UUID()
        paneFrameHandlers[paneID, default: [:]][id] = handler
        return id
    }

    func addConnectionGenerationHandler(
        _ handler: @escaping (UInt64) -> Void
    ) -> UUID {
        let id = UUID()
        connectionGenerationHandlers[id] = handler
        handler(connectionGeneration)
        return id
    }

    func removeConnectionGenerationHandler(_ id: UUID) {
        connectionGenerationHandlers.removeValue(forKey: id)
    }

    func removePaneFrameHandler(for paneID: String, id: UUID) {
        paneFrameHandlers[paneID]?.removeValue(forKey: id)
        if paneFrameHandlers[paneID]?.isEmpty == true {
            paneFrameHandlers.removeValue(forKey: paneID)
        }
    }

    func addPaneScrollbackHandler(
        for paneID: String,
        handler: @escaping (Data) -> Void
    ) -> UUID {
        let id = UUID()
        paneScrollbackHandlers[paneID, default: [:]][id] = handler
        if let pending = pendingScrollback.removeValue(forKey: paneID) {
            handler(pending)
        }
        return id
    }

    func removePaneScrollbackHandler(for paneID: String, id: UUID) {
        paneScrollbackHandlers[paneID]?.removeValue(forKey: id)
        if paneScrollbackHandlers[paneID]?.isEmpty == true {
            paneScrollbackHandlers.removeValue(forKey: paneID)
        }
    }

    func sendKeys(_ keys: [String], to paneID: String) {
        sendAction(.sendKeys(paneID: paneID, keys: keys))
    }

    func decide(
        _ decision: RemotePermissionDecision,
        requestID: String,
        paneID: String
    ) {
        sendAction(.decide(paneID: paneID, requestID: requestID, decision: decision))
    }

    func sendInput(_ bytes: [UInt8], to paneID: String) {
        Task {
            do {
                try await send(
                    .input(
                        paneID: paneID,
                        bytesBase64: Data(bytes).base64EncodedString()
                    )
                )
            } catch {
                handleSocketFailure(error)
            }
        }
    }

    /// A whole composed line, held until it can actually be delivered.
    ///
    /// Deliberately NOT the path raw keystrokes take. A composed line is
    /// self-contained and carries its own carriage return, so replaying it
    /// late still means what the user meant. A lone `y` does not — replayed
    /// against whatever prompt exists minutes later it answers a question
    /// nobody asked. Direct-mode keys keep the old fire-and-forget behavior.
    ///
    /// Returns whether Rai delivered, queued, or refused the line.
    @discardableResult
    func sendComposedLine(_ bytes: [UInt8], to paneID: String) async -> ComposedLineSendResult {
        switch passwordPromptState(for: paneID) {
        case .prompt:
            refusePasswordPromptSend(to: paneID)
            return .refused
        case .unknown:
            actionError = PasswordPromptGuard.waiting
            enqueue(bytes, to: paneID)
            return .queued
        case .clear:
            if actionError == PasswordPromptGuard.waiting {
                actionError = nil
            }
            break
        }
        if status.isConnected {
            do {
                try await send(
                    .input(paneID: paneID, bytesBase64: Data(bytes).base64EncodedString())
                )
                return .accepted
            } catch {
                handleSocketFailure(error)
            }
        }
        enqueue(bytes, to: paneID)
        return .queued
    }

    private func enqueue(_ bytes: [UInt8], to paneID: String) {
        let autoReplayUsed = outbox.first(where: { $0.paneID == paneID })?.autoReplayUsed ?? false
        // A bounded queue: a phone left offline should not accumulate an
        // unbounded replay that lands all at once hours later.
        if outbox.count >= Self.outboxLimit {
            outbox.removeFirst(outbox.count - Self.outboxLimit + 1)
        }
        outbox.append(
            QueuedLine(
                paneID: paneID,
                bytes: bytes,
                queuedAt: now(),
                autoReplayUsed: autoReplayUsed
            )
        )
        if !status.isConnected { retryNow() }
    }

    func discardOutbox() {
        outbox.removeAll()
    }

    func discardOutbox(for paneID: String) {
        outbox.removeAll(where: { $0.paneID == paneID })
    }

    func queuedLineCount(for paneID: String) -> Int {
        outbox.count(where: { $0.paneID == paneID })
    }

    func takePendingComposedDraft(for paneID: String) -> String? {
        pendingComposedDrafts.removeValue(forKey: paneID)
    }

    func keepPendingComposedDraft(_ text: String, for paneID: String) {
        pendingComposedDrafts[paneID] = text
    }

    func updateVisibleGrid(_ grid: String, for paneID: String) {
        latestGridByPaneID[paneID] = PasswordPromptGridEvidence(
            generation: connectionGeneration,
            grid: grid
        )
        if !outbox.isEmpty {
            flushOutbox(for: paneID)
        }
    }

    /// Replay at most one line per pane after a reconnect. Later lines need a
    /// user tap, because output timing cannot prove that a prompt did not open.
    private func flushOutbox(for paneID: String? = nil) {
        guard status.isConnected, !outbox.isEmpty else { return }
        let expired = expireOutbox()
        guard !outbox.isEmpty else { return }

        let paneIDs = paneID.map { Set([$0]) } ?? Set(outbox.map(\.paneID))
        for candidatePaneID in paneIDs {
            guard let index = outbox.firstIndex(where: { $0.paneID == candidatePaneID }),
                  !outbox[index].autoReplayUsed else {
                continue
            }
            switch passwordPromptState(for: candidatePaneID) {
            case .prompt:
                refusePasswordPromptSend(to: candidatePaneID)
            case .unknown:
                if expired == 0 {
                    actionError = PasswordPromptGuard.waiting
                }
            case .clear:
                for queuedIndex in outbox.indices where outbox[queuedIndex].paneID == candidatePaneID {
                    outbox[queuedIndex].autoReplayUsed = true
                }
                sendQueuedLine(at: index)
            }
        }
    }

    @discardableResult
    private func expireOutbox() -> Int {
        let currentTime = now()
        let expired = outbox.count(where: {
            currentTime.timeIntervalSince($0.queuedAt) > Self.outboxStaleness
        })
        outbox.removeAll(where: {
            currentTime.timeIntervalSince($0.queuedAt) > Self.outboxStaleness
        })
        if expired > 0 {
            actionError = "\(expired) queued line\(expired == 1 ? "" : "s") expired unsent"
        }
        return expired
    }

    private func sendQueuedLine(at index: Int) {
        let line = outbox.remove(at: index)
        if actionError == PasswordPromptGuard.waiting {
            actionError = nil
        }
        Task {
            do {
                try await send(
                    .input(
                        paneID: line.paneID,
                        bytesBase64: Data(line.bytes).base64EncodedString()
                    )
                )
            } catch {
                outbox.insert(line, at: min(index, outbox.endIndex))
                handleSocketFailure(error)
            }
        }
    }

    func sendNextQueuedLine(for paneID: String) async -> ComposedLineSendResult {
        expireOutbox()
        guard let index = outbox.firstIndex(where: { $0.paneID == paneID }) else {
            return .queued
        }
        switch passwordPromptState(for: paneID) {
        case .prompt:
            refusePasswordPromptSend(to: paneID)
            return .refused
        case .unknown:
            actionError = PasswordPromptGuard.waiting
            return .queued
        case .clear:
            break
        }
        guard status.isConnected else {
            actionError = PasswordPromptGuard.waiting
            return .queued
        }
        let line = outbox.remove(at: index)
        do {
            try await send(
                .input(
                    paneID: line.paneID,
                    bytesBase64: Data(line.bytes).base64EncodedString()
                )
            )
            if actionError == PasswordPromptGuard.waiting {
                actionError = nil
            }
            return .accepted
        } catch {
            outbox.insert(line, at: min(index, outbox.endIndex))
            handleSocketFailure(error)
            return .queued
        }
    }

    struct QueuedLine: Identifiable, Equatable {
        let id = UUID()
        let paneID: String
        let bytes: [UInt8]
        let queuedAt: Date
        var autoReplayUsed: Bool
        var text: String { String(decoding: bytes, as: UTF8.self) }
    }

    private static let outboxLimit = 20
    private static let outboxStaleness: TimeInterval = 15 * 60

    @discardableResult
    private func refusePasswordPromptSend(to paneID: String) -> Bool {
        guard passwordPromptState(for: paneID) == .prompt else {
            return false
        }
        let dropped = outbox.count(where: { $0.paneID == paneID })
        outbox.removeAll(where: { $0.paneID == paneID })
        actionError = PasswordPromptGuard.refusalMessage(droppedQueuedLines: dropped)
        return true
    }

    private func passwordPromptState(for paneID: String) -> PasswordPromptGuard.State {
        guard let evidence = latestGridByPaneID[paneID],
              evidence.generation == connectionGeneration else {
            return .unknown
        }
        return PasswordPromptGuard.isPasswordPrompt(evidence.grid) ? .prompt : .clear
    }

    func sendImage(_ data: Data, filename: String, to paneID: String) async throws {
        try await send(
            .sendImage(
                paneID: paneID,
                bytesBase64: data.base64EncodedString(),
                filename: filename
            )
        )
    }

    /// Notification actions can arrive while the app is suspended. Reuse the
    /// live socket when possible, otherwise reconnect and wait briefly for the
    /// authenticated welcome before sending within the notification window.
    func connectAndSendInput(
        _ bytes: [UInt8],
        to paneID: String,
        pairing: Pairing
    ) async -> Bool {
        if !status.isConnected {
            connect(to: pairing)
            for _ in 0..<80 {
                if status.isConnected { break }
                if requiresRepair { return false }
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return false }
            }
        }
        guard status.isConnected else { return false }
        do {
            try await send(
                .input(
                    paneID: paneID,
                    bytesBase64: Data(bytes).base64EncodedString()
                )
            )
            return true
        } catch {
            handleSocketFailure(error)
            return false
        }
    }

    /// Notification replies are complete lines and use the same prompt guard.
    func connectAndSendComposedLine(
        _ bytes: [UInt8],
        to paneID: String,
        pairing: Pairing
    ) async -> Bool {
        if queueNotificationReplyBehindOutboxIfNeeded(bytes, paneID: paneID) {
            return false
        }
        let clock = ContinuousClock()
        let waitDuration = Duration.milliseconds(
            Int64(max(replyFrameWaitIterations, 0)) * 100
        )
        let deadline = clock.now.advanced(by: waitDuration)
        if !status.isConnected {
            guard clock.now < deadline else {
                return replyVerificationTimedOut(bytes, paneID: paneID)
            }
            connect(to: pairing)
            while !status.isConnected {
                if requiresRepair { return false }
                guard clock.now < deadline else {
                    return replyVerificationTimedOut(bytes, paneID: paneID)
                }
                let nextCheck = min(
                    deadline,
                    clock.now.advanced(by: .milliseconds(100))
                )
                try? await clock.sleep(until: nextCheck)
                if Task.isCancelled { return false }
            }
        }
        guard status.isConnected, clock.now < deadline else {
            return replyVerificationTimedOut(bytes, paneID: paneID)
        }
        var attachedTemporaryStream = false
        if passwordPromptState(for: paneID) == .unknown, desiredStreams[paneID] == nil {
            guard clock.now < deadline else {
                return replyVerificationTimedOut(bytes, paneID: paneID)
            }
            do {
                try await send(
                    .attachStream(paneID: paneID, cols: 80, rows: 24, fullGrid: true)
                )
                attachedTemporaryStream = true
            } catch {
                handleSocketFailure(error)
                return false
            }
        }
        guard clock.now < deadline else {
            if attachedTemporaryStream {
                Task { try? await send(.detachStream(paneID: paneID)) }
            }
            return replyVerificationTimedOut(bytes, paneID: paneID)
        }
        actionError = PasswordPromptGuard.waiting
        while passwordPromptState(for: paneID) == .unknown {
            guard status.isConnected else {
                return replyVerificationTimedOut(bytes, paneID: paneID)
            }
            guard clock.now < deadline else { break }
            let nextCheck = min(
                deadline,
                clock.now.advanced(by: .milliseconds(100))
            )
            try? await clock.sleep(until: nextCheck)
            if Task.isCancelled { return false }
        }
        guard clock.now < deadline,
              passwordPromptState(for: paneID) != .unknown else {
            if attachedTemporaryStream {
                Task { try? await send(.detachStream(paneID: paneID)) }
            }
            return replyVerificationTimedOut(bytes, paneID: paneID)
        }
        if queueNotificationReplyBehindOutboxIfNeeded(bytes, paneID: paneID) {
            if attachedTemporaryStream {
                Task { try? await send(.detachStream(paneID: paneID)) }
            }
            return false
        }
        guard clock.now < deadline else {
            if attachedTemporaryStream {
                Task { try? await send(.detachStream(paneID: paneID)) }
            }
            return replyVerificationTimedOut(bytes, paneID: paneID)
        }
        let result = await sendComposedLine(bytes, to: paneID)
        if attachedTemporaryStream { try? await send(.detachStream(paneID: paneID)) }
        return result == .accepted
    }

    private func queueNotificationReplyBehindOutboxIfNeeded(
        _ bytes: [UInt8],
        paneID: String
    ) -> Bool {
        guard outbox.contains(where: { $0.paneID == paneID }) else { return false }
        enqueue(bytes, to: paneID)
        return true
    }

    private static func composedDraft(from bytes: [UInt8]) -> String {
        let content = bytes.last == 0x0D ? bytes.dropLast() : bytes[...]
        return String(decoding: content, as: UTF8.self)
    }

    private func replyVerificationTimedOut(_ bytes: [UInt8], paneID: String) -> Bool {
        actionError = PasswordPromptGuard.verificationFailure
        keepPendingComposedDraft(Self.composedDraft(from: bytes), for: paneID)
        return false
    }

    func connectAndDecide(
        _ decision: RemotePermissionDecision,
        requestID: String,
        paneID: String,
        pairing: Pairing
    ) async -> Bool {
        if !status.isConnected {
            connect(to: pairing)
            for _ in 0..<80 {
                if status.isConnected { break }
                if requiresRepair { return false }
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return false }
            }
        }
        guard status.isConnected else { return false }
        guard let decisionSocket = task else { return false }
        guard decisionWaiters[requestID] == nil else { return false }
        return await withCheckedContinuation { continuation in
            decisionWaiters[requestID] = DecisionWaiter(
                socket: decisionSocket,
                continuation: continuation
            )
            Task {
                do {
                    try await sendDecision(
                        .decide(
                            paneID: paneID,
                            requestID: requestID,
                            decision: decision
                        ),
                        over: decisionSocket
                    )
                } catch {
                    resolveDecision(requestID: requestID, accepted: false)
                    handleSocketFailure(error, from: decisionSocket)
                    return
                }
                try? await Task.sleep(for: .seconds(5))
                resolveDecision(requestID: requestID, accepted: false)
            }
        }
    }

    func registerPush(deviceToken: String, environment: String) {
        Task {
            do {
                let availability = decisionAvailability
                for message in PushRegistrationPlan.messages(
                    deviceToken: deviceToken,
                    environment: environment,
                    availability: availability
                ) {
                    try await send(message)
                }
            } catch {
                handleSocketFailure(error)
            }
        }
    }

    /// Best-effort unregister on the still-open socket. Awaited so callers can
    /// flush it before tearing the connection down (e.g. forgetting a pairing).
    func unregisterPush(deviceToken: String) async {
        try? await send(.unregisterPush(deviceToken: deviceToken))
    }

    private func openSocket() {
        guard let url = webSocketURL(), shouldReconnect else {
            status = .failed(.invalidAddress(host: host))
            return
        }

        reconnectTask?.cancel()
        if status.diagnosis == nil {
            status = .connecting
        }
        let socket = URLSession.shared.webSocketTask(with: url)
        task = socket
        socket.resume()

        receiveTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.sendAuthentication()
                try await self.receiveMessages(from: socket)
            } catch is CancellationError {
                return
            } catch {
                self.handleSocketFailure(error, from: socket)
            }
        }
    }

    private func sendAuthentication() async throws {
        let client = clientInfo()
        if let invitation {
            try await send(
                .pair(
                    code: invitation.code,
                    protocolVersion: bridgeProtocolVersion,
                    client: client
                )
            )
        } else if let pairing {
            try await send(.hello(token: pairing.token, client: client))
        } else {
            throw URLError(.userAuthenticationRequired)
        }
    }

    private func clientInfo() -> ClientInfo {
        let defaults = UserDefaults.standard
        let deviceIDKey = "bridge.deviceID"
        let deviceID: String
        if let existing = defaults.string(forKey: deviceIDKey) {
            deviceID = existing
        } else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: deviceIDKey)
        }
        return ClientInfo(
            deviceID: deviceID,
            name: UIDevice.current.name,
            platform: "iOS",
            model: UIDevice.current.model,
            capabilities: decisionAvailability.capabilities
        )
    }

    private func receiveMessages(from socket: URLSessionWebSocketTask) async throws {
        while !Task.isCancelled {
            let frame = try await socket.receive()
            guard task === socket else { return }
            let data: Data
            switch frame {
            case let .string(text):
                data = Data(text.utf8)
            case .data:
                continue
            @unknown default:
                continue
            }
            // A message this client can't decode (e.g. a newer Mac added a
            // message type) must not kill the connection: throwing here would
            // reconnect, replay the same message, and loop forever. Skip it —
            // true incompatibility is caught by the authentication reply check.
            do {
                handle(try decoder.decode(BridgeMessage.self, from: data))
            } catch {
                NSLog(
                    "rai-ios: skipping undecodable bridge message: %@",
                    String(describing: error)
                )
            }
        }
    }

    func handle(_ message: BridgeMessage) {
        switch message {
        case let .paired(token, protocolVersion, _):
            guard protocolVersion == bridgeProtocolVersion else {
                stopWithFailure(.protocolMismatch(protocolVersion))
                return
            }
            guard let invitation,
                  let pairing = try? Self.exchangedPairing(token: token, invitation: invitation)
            else {
                stopWithFailure(.invalidPairingReply())
                return
            }
            // The Mac closes the socket if anything but `hello` follows
            // `pair`. Publishing the pairing first lets the monitor screen
            // appear and fire its own requests (list sessions, refresh) in a
            // separate task that can beat the hello onto the wire, so the
            // pairing then fails with "Pair Again". Send hello, and only
            // then publish the pairing and let the UI switch.
            // The connection's own `pairing` is set now so a fast `welcome`
            // finds it; the UI switch (`didPair`) waits for the hello send.
            self.pairing = pairing
            self.invitation = nil
            let hello = BridgeMessage.hello(token: pairing.token, client: clientInfo())
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.send(hello)
                    self.didPair?(pairing)
                } catch {
                    self.handleSocketFailure(error)
                }
            }
        case let .welcome(protocolVersion, sessionName):
            guard invitation == nil, pairing != nil else {
                stopWithFailure(.invalidPairingReply())
                return
            }
            finishAuthentication(protocolVersion: protocolVersion, sessionName: sessionName)
        case let .authFailed(reason, code, detail, unrecognizedCode):
            if let code {
                handleCodedError(
                    code,
                    message: reason,
                    detail: detail,
                    phase: .authentication
                )
            } else {
                handleAuthenticationProse(
                    reason: reason,
                    detail: detail,
                    unrecognizedCode: unrecognizedCode
                )
            }
        case let .snapshot(snapshot):
            replaceWithLiveSnapshot(snapshot)
        case let .sessions(list):
            sessions = list
            if let current = list.first(where: { $0.isCurrent }) {
                sessionName = current.name
            }
        case let .backgroundWork(work):
            didReceiveBackgroundWork?(work)
        case let .pushPrefsState(preferences):
            pushPreferences = preferences
            supportsPushPreferences = true
            if pendingPushPreferences?.effective(at: Date()) == preferences {
                clearPendingPushPreferences()
            } else if pendingPushPreferences == nil {
                synchronizePushPreferencesTimeZone()
            }
        case let .paneFrame(paneID, bytesBase64, full, _, cols, rows):
            guard let data = Data(base64Encoded: bytesBase64) else { return }
            // Older Macs omit the frame's grid dimensions; clients then fall
            // back to sizing the emulator from the view.
            let grid: PaneGridSize? = if let cols, let rows, cols > 0, rows > 0 {
                PaneGridSize(cols: cols, rows: rows)
            } else {
                nil
            }
            if let text = passwordPromptGridReader.apply(
                data: data,
                full: full,
                size: grid,
                paneID: paneID
            ) {
                updateVisibleGrid(text, for: paneID)
            }
            guard let handlers = paneFrameHandlers[paneID]?.values else { return }
            for handler in handlers {
                handler(data, full, grid)
            }
        case let .scrollback(paneID, bytesBase64):
            seededPanes.insert(paneID)
            // An EMPTY seed is the NORMAL reply for an agent on the alt screen:
            // `pane read --source recent` returns just the current screen, and
            // the Mac drops a screenful from the tail so the seam can't show it
            // twice — for Claude that trims the payload to nothing.
            //
            // It still has to reach the handler. The handler's full reset is
            // the only thing that clears the previous visit's rows, so dropping
            // an empty seed here left stale history sitting above the live
            // screen every time the user came back to an agent.
            let data = Data(base64Encoded: bytesBase64) ?? Data()
            guard let handlers = paneScrollbackHandlers[paneID]?.values,
                  !handlers.isEmpty else {
                pendingScrollback[paneID] = data
                return
            }
            for handler in handlers {
                handler(data)
            }
        case let .error(message, code, detail):
            if let code {
                handleCodedError(code, message: message, detail: detail, phase: .operation)
                return
            }
            if Self.isPairingProtocolRejection(
                message,
                pairingInProgress: invitation != nil
            ) {
                stopWithFailure(.macPredatesPairing())
            } else if message.hasPrefix("Invalid bridge message")
                || message.hasPrefix("Could not read scrollback") {
                // Old Mac that predates readScrollback, or a transient history
                // read failure. Scrollback is progressive enhancement; don't
                // drop or flag a healthy connection over it.
                NSLog("rai-ios: scrollback unavailable: %@", message)
            } else if Self.isActionError(message) {
                actionError = message
            } else {
                status = .failed(.bridgeError(message, host: host))
            }
        case let .paneError(_, message):
            actionError = message
        case let .decisionResult(_, requestID, accepted, message):
            if !accepted {
                actionError = message ?? "That prompt already closed"
            }
            resolveDecision(requestID: requestID, accepted: accepted)
        case .event:
            break
        case .pair, .hello, .subscribe, .attachStream, .detachStream,
             .input, .sendImage, .focusPane, .selectPane, .resizePane,
             .launchAgent, .renamePane, .renameTab, .closePane, .closeTab,
             .registerPush, .unregisterPush, .readScrollback,
             .renameWorkspace, .closeWorkspace, .broadcastInput, .sendKeys, .decide,
             .decisionAvailability, .listSessions, .selectSession, .pushPrefs:
            break
        }
    }

    static func exchangedPairing(token: String, invitation: PairingInvitation) throws -> Pairing {
        try invitation.credential(token: token)
    }

    static func isPairingProtocolRejection(
        _ message: String,
        pairingInProgress: Bool
    ) -> Bool {
        pairingInProgress && message.hasPrefix("Invalid bridge message")
    }

    func finishAuthentication(protocolVersion: Int, sessionName: String?) {
        guard protocolVersion == bridgeProtocolVersion else {
            stopWithFailure(.protocolMismatch(protocolVersion))
            return
        }
        // A welcome starts a new authenticated screen generation. This also
        // invalidates prompt controls and any password grid from the old socket.
        advanceConnectionGeneration()
        reconnectAttempt = 0
        status = .connected
        self.sessionName = sessionName
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.send(.subscribe)
                if let pending = self.pendingPushPreferences {
                    try await self.send(.pushPrefs(pending))
                }
                self.didConnect?()
                self.requestSessions()
                self.flushOutbox()
                for (paneID, size) in self.desiredStreams {
                    let needsSeed = !self.seededPanes.contains(paneID)
                    if needsSeed {
                        try await self.send(
                            .readScrollback(
                                paneID: paneID,
                                lines: 1000,
                                rows: size.rows,
                                fullGrid: true
                            )
                        )
                    }
                    try await self.send(
                        .attachStream(
                            paneID: paneID,
                            cols: size.cols,
                            rows: size.rows,
                            fullGrid: true
                        )
                    )
                }
            } catch {
                self.handleSocketFailure(error)
            }
        }
    }

    /// Named herdr sessions the Mac can watch (empty until the Mac replies).
    func requestSessions() {
        Task {
            try? await send(.listSessions)
        }
    }

    /// Switches the herd the Mac — and therefore this phone — watches.
    func switchSession(named name: String) {
        guard name != sessionName else { return }
        Task {
            try? await send(.selectSession(name: name))
            // The Mac pushes a fresh snapshot on switch; refresh the session
            // list too so the checkmark follows.
            try? await Task.sleep(for: .seconds(1.5))
            try? await send(.listSessions)
        }
    }

    private static func isActionError(_ message: String) -> Bool {
        message.hasPrefix("Bridge audit ")
            || message == "Agent must be claude or codex."
            || message.hasPrefix("Unknown workspace ")
            || message.hasPrefix("Could not launch ")
            || message.hasPrefix("Could not rename ")
            || message.hasPrefix("Could not close ")
    }

    private func handleCodedError(
        _ code: BridgeErrorCode,
        message: String,
        detail: String?,
        phase: BridgeErrorPhase
    ) {
        let destination = BridgeErrorPolicy.destination(for: code, phase: phase)
        switch destination {
        case .actionError:
            actionError = message
        case .reconnect, .pairAgain, .updateRequired:
            let diagnosis = ConnectionDiagnosis.coded(
                code,
                message: message,
                detail: detail,
                host: host
            )
            if phase == .authentication, destination == .reconnect {
                retryAuthentication(after: diagnosis)
            } else if phase == .authentication {
                stopWithFailure(diagnosis)
            } else {
                status = .failed(diagnosis)
            }
        case .ignore:
            NSLog("rai-ios: optional bridge feature unavailable: %@", detail ?? message)
        }
    }

    private func handleAuthenticationProse(
        reason: String,
        detail: String?,
        unrecognizedCode: String?
    ) {
        let rawDetails = detail ?? reason
        switch BridgeErrorPolicy.authenticationProseDestination(reason) {
        case .pairAgain:
            stopWithFailure(.helloRejected(reason: rawDetails))
        case .updateRequired:
            stopWithFailure(ConnectionDiagnosis(
                message: "Rai versions don't match — update Rai on the Mac or iPhone",
                rawDetails: rawDetails,
                action: .reconnect
            ))
        case .reconnect:
            let diagnosis = ConnectionDiagnosis.bridgeError(reason, host: host)
            retryAuthentication(after: ConnectionDiagnosis(
                message: diagnosis.message,
                rawDetails: unrecognizedCode.map { "\($0): \(rawDetails)" } ?? rawDetails,
                action: .reconnect
            ))
        case .actionError, .ignore:
            break
        }
    }

    private func retryAuthentication(after diagnosis: ConnectionDiagnosis) {
        shouldReconnect = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        receiveTask?.cancel()
        receiveTask = nil
        scheduleReconnect(
            after: NSError(
                domain: "RaiBridgeAuthentication",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: diagnosis.rawDetails]
            ),
            diagnosis: diagnosis
        )
    }

    private func storePendingPushPreferences(_ preferences: PushPreferences) {
        pendingPushPreferences = preferences
        let stored = StoredPendingPushPreferences(preferences: preferences)
        if let data = try? JSONEncoder().encode(stored) {
            userDefaults.set(data, forKey: Self.pendingPushPreferencesKey)
        }
    }

    private func clearPendingPushPreferences() {
        pendingPushPreferences = nil
        userDefaults.removeObject(forKey: Self.pendingPushPreferencesKey)
    }

    private func synchronizePushPreferencesTimeZone() {
        guard supportsPushPreferences else { return }
        let source = pendingPushPreferences ?? pushPreferences
        guard source.dnd != nil else { return }
        let localized = PushPreferencesTimeZoneSync.applyingCurrentZone(
            to: source,
            timeZone: currentTimeZone()
        )
        guard localized != source else { return }
        setPushPreferences(localized)
    }

    private func send(_ message: BridgeMessage) async throws {
        if let messageSender {
            try await messageSender(message)
            return
        }
        guard let task else { throw URLError(.notConnectedToInternet) }
        let data = try encoder.encode(message)
        guard let text = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        // Until `welcome`, the Mac accepts only `pair` and `hello`; anything
        // else makes it close the socket, and the pairing fails with "Pair
        // Again". The monitor screen is already on screen while a pairing is
        // pending and fires requests (list sessions, refresh) of its own, so
        // drop those here. `finishAuthentication` re-issues subscribe, the
        // session list, and the outbox once the Mac has said welcome.
        let isHandshake: Bool
        switch message {
        case .pair, .hello: isHandshake = true
        default: isHandshake = false
        }
        if !status.isConnected, !isHandshake {
            if let range = text.range(of: #""type":"[A-Za-z]+""#, options: .regularExpression) {
                NSLog("rai-ios: dropped %@ before welcome", String(text[range]))
            }
            return
        }
        try await task.send(.string(text))
    }

    private func sendDecision(
        _ message: BridgeMessage,
        over socket: URLSessionWebSocketTask
    ) async throws {
        guard task === socket, status.isConnected else {
            throw URLError(.notConnectedToInternet)
        }
        let data = try encoder.encode(message)
        guard let text = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        try await socket.send(.string(text))
    }

    private func handleSocketFailure(
        _ error: Error,
        from socket: URLSessionWebSocketTask? = nil
    ) {
        if let socket, task !== socket {
            resolveDecisions(for: socket, accepted: false)
            return
        }
        if let socket = socket ?? task {
            resolveDecisions(for: socket, accepted: false)
        } else {
            resolveAllDecisions(accepted: false)
        }
        guard shouldReconnect, !(error is CancellationError) else { return }
        scheduleReconnect(after: error)
    }

    func scheduleReconnect(
        after error: Error,
        diagnosis: ConnectionDiagnosis? = nil
    ) {
        NSLog("rai-ios: connection lost, will reconnect: %@", String(describing: error))
        guard reconnectTask == nil || reconnectTask?.isCancelled == true else { return }
        advanceConnectionGeneration()
        task = nil
        receiveTask = nil
        reconnectAttempt += 1
        status = .failed(diagnosis ?? .transport(error, host: host))
        let delay = min(pow(2.0, Double(reconnectAttempt - 1)), 30)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.shouldReconnect else { return }
            self.reconnectTask = nil
            self.openSocket()
        }
    }

    private func stopWithFailure(_ diagnosis: ConnectionDiagnosis) {
        // One line per hard failure so a simulator run (`log show`) or a
        // device console says why the phone gave up, not just that it did.
        NSLog("rai-ios: connection failed: %@ — %@", diagnosis.message, diagnosis.rawDetails)
        advanceConnectionGeneration()
        shouldReconnect = false
        task?.cancel(with: .policyViolation, reason: nil)
        task = nil
        receiveTask?.cancel()
        receiveTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        status = .failed(diagnosis)
        resolveAllDecisions(accepted: false)
    }

    private func disconnect(clearPairing: Bool, clearSnapshot: Bool) {
        advanceConnectionGeneration()
        resolveAllDecisions(accepted: false)
        shouldReconnect = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        receiveTask?.cancel()
        receiveTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        status = .disconnected
        supportsPushPreferences = false
        if clearSnapshot {
            snapshot = nil
            lastSnapshotAt = nil
            decisionBeaconReceivedAt.removeAll()
            isShowingCachedSnapshot = false
        }
        sessionName = nil
        didReceiveBackgroundWork?([])
        desiredStreams.removeAll()
        seededPanes.removeAll()
        if clearPairing {
            clearPendingPushPreferences()
            pairing = nil
            invitation = nil
        }
    }

    private func resolveDecision(requestID: String, accepted: Bool) {
        decisionWaiters.removeValue(forKey: requestID)?.continuation.resume(
            returning: accepted
        )
    }

    private func resolveDecisions(for socket: URLSessionWebSocketTask, accepted: Bool) {
        let socketIDs = decisionWaiters.mapValues { ObjectIdentifier($0.socket) }
        let requestIDs = DecisionWaiterRouting.requestIDs(
            waiterSocketIDs: socketIDs,
            failingSocketID: ObjectIdentifier(socket)
        )
        for requestID in requestIDs {
            resolveDecision(requestID: requestID, accepted: accepted)
        }
    }

    private func resolveAllDecisions(accepted: Bool) {
        let waiters = Array(decisionWaiters.values.map(\.continuation))
        decisionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: accepted)
        }
    }

    private func advanceConnectionGeneration() {
        connectionGeneration &+= 1
        latestGridByPaneID.removeAll()
        passwordPromptGridReader.removeAll()
        for handler in connectionGenerationHandlers.values {
            handler(connectionGeneration)
        }
    }

    private func webSocketURL() -> URL? {
        let host = pairing?.host ?? invitation?.host
        let port = pairing?.port ?? invitation?.port
        let useTLS = pairing?.useTLS ?? invitation?.useTLS
        guard let host, let port, let useTLS else { return nil }
        var components = URLComponents()
        components.scheme = useTLS ? "wss" : "ws"
        components.host = host
        components.port = port
        components.path = "/"
        return components.url
    }

}
