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

    static func isConnectionLevel(
        _ code: BridgeErrorCode,
        phase: BridgeErrorPhase
    ) -> Bool {
        switch destination(for: code, phase: phase) {
        case .reconnect, .pairAgain, .updateRequired:
            true
        case .actionError, .ignore:
            false
        }
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
            message: "Herdr is unavailable on the Mac. Open Rai there to install or start Herdr.",
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
        if isHerdUnavailable(message) {
            return herdMissing(rawDetails: message)
        }
        return serverError(message, host: host)
    }

    static func isHerdUnavailable(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "herdr is not connected." || normalized == "herdr is unavailable."
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

/// What a pane frame carries. A `preview` is the Mac's pane read (sequence 0)
/// sent before its observe stream starts; `full` is a stream baseline.
enum PaneFrameKind: Equatable {
    case delta
    case full
    case preview

    var isFull: Bool { self != .delta }
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

private enum ReplyAttachmentResult: Sendable {
    case attached
    case failed
    case timedOut
}

private actor ReplyAttachmentRace {
    private var result: ReplyAttachmentResult?
    private var waiter: CheckedContinuation<ReplyAttachmentResult, Never>?

    func wait() async -> ReplyAttachmentResult {
        if let result { return result }
        return await withCheckedContinuation { waiter = $0 }
    }

    @discardableResult
    func finish(with result: ReplyAttachmentResult) -> Bool {
        guard self.result == nil else { return false }
        self.result = result
        waiter?.resume(returning: result)
        waiter = nil
        return true
    }
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
        let socket: any BridgeSocket
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
    @Published private(set) var machines = MachineDirectoryState()
    private var machineListRequested = false
    private var selectedMachine: MachineEndpoint?
    private var pendingMachineAgent: MachineResource?
    private var pendingMachineNotification: MachineResource?
    private var machineNotificationRequiresSelection = false
    let endpointView = EndpointPhoneModel()
    private var endpointViewRequested = false
    @Published private(set) var hostCapabilities: BridgeHostCapabilities?
    @Published var agentExplanation: AgentExplanation?
    @Published private(set) var herdrManagementRequest: HerdrManagementRequest?
    @Published private(set) var herdrManagementText: String?
    @Published private(set) var isShowingCachedSnapshot = false
    @Published private(set) var lastSnapshotAt: Date?
    @Published private(set) var actionError: String?
    @Published private(set) var sessionName: String?
    @Published private(set) var sessions: [BridgeSessionInfo] = []
    @Published private(set) var historyPages: [String: TranscriptHistoryPage] = [:]
    @Published private(set) var historyErrors: [String: String] = [:]
    @Published private(set) var historyFromPreviousSession: Set<String> = []
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
    var didReceiveHistoryPages: (([String: TranscriptHistoryPage]) -> Void)?

    var requiresRepair: Bool {
        status.diagnosis?.action == .pairAgain
    }

    var hasPendingReconnect: Bool {
        reconnectTask != nil
    }

    /// Includes a retry handshake and waiting for a usable network path.
    /// A server-side operation failure on an open socket is not a retry.
    var isRecoveringConnection: Bool {
        shouldReconnect && !status.isConnected && !requiresRepair
            && (reconnectTask != nil || handshakeDeadline != nil
                || historyPacing.path?.allowsConnectionAttempts == false)
    }

    var isSnapshotStale: Bool {
        snapshot != nil && (isShowingCachedSnapshot || !status.isConnected)
    }

    var pendingHistoryRequestCount: Int {
        pendingHistoryRequests.count
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

    private var task: (any BridgeSocket)?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var handshakeDeadline: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var pongDeadline: Task<Void, Never>?
    private var pendingPing: UUID?
    private var hasSentPing = false
    private var pathMonitor: NWPathMonitor?
    private var pathMonitorID: UUID?
    private let socketFactory: (URL) -> any BridgeSocket
    private let networkTiming: BridgeNetworkTiming
    private let monitorsNetwork: Bool
    private let uptime: () -> TimeInterval
    private var historyPacing = BridgeHistoryPacing()
    private var historyReadStarted: [String: TimeInterval] = [:]

    var scrollbackRefreshInterval: TimeInterval { historyPacing.interval }
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
        replyFrameWaitIterations: Int = 50,
        socketFactory: @escaping (URL) -> any BridgeSocket = {
            let socket = URLSession.shared.webSocketTask(with: $0)
            socket.maximumMessageSize = 16 * 1024 * 1024
            return socket
        },
        networkTiming: BridgeNetworkTiming = BridgeNetworkTiming(),
        monitorsNetwork: Bool = true,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.socketFactory = socketFactory
        self.networkTiming = networkTiming
        self.monitorsNetwork = monitorsNetwork
        self.uptime = uptime
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
    private var paneFrameHandlers: [String: [UUID: (Data, PaneFrameKind, PaneGridSize?) -> Void]] = [:]
    private var paneScrollbackHandlers: [String: [UUID: (Data) -> Void]] = [:]
    private var latestGridByPaneID: [String: PasswordPromptGridEvidence] = [:]
    private let passwordPromptGridReader = PasswordPromptGridReader()
    // A seed can land before the terminal view has registered its handler
    // (openPane fires from onAppear, which can precede makeUIView). Hold the
    // payload and deliver it on registration instead of dropping it.
    private var pendingScrollback: [String: Data] = [:]
    private var desiredStreams: [String: (cols: Int, rows: Int)] = [:]
    private var paneOpenIDs: [String: UUID] = [:]
    private var historyGeneration: UInt = 0
    private var historySessionName: String?
    private var pendingHistoryRequests: [String: PendingHistoryRequest] = [:]
    private var knownHistorySessions: [String: String] = [:]
    private var historyLastAccess: [String: Date] = [:]
    private var historyMissingSince: [String: Date] = [:]
    private var historyPruneTask: Task<Void, Never>?
    private var activePaneID: String?
    // Panes whose scrollback seed actually arrived. Tracked separately from
    // desiredStreams so a seed lost to a dropped connection (opening a pane
    // while reconnecting is routine on a phone) is retried on the next
    // welcome instead of being skipped forever.
    private var seededPanes: Set<String> = []
    let terminalViewCache = TerminalViewCache()
    private var terminalCacheScope = UUID()
    private var scrollbackHashes: [String: String] = [:]
    private var scrollbackRefreshTasks: [String: Task<Void, Never>] = [:]
    private var scrollbackRefreshInFlight: Set<String> = []
    private var dirtyScrollback: Set<String> = []
    private var decisionBeaconReceivedAt: [String: Date] = [:]
    private var decisionWaiters: [String: DecisionWaiter] = [:]
    private var notificationAuthorizationGranted = false
    private var appIsForeground = false

    func updateDecisionAvailability(
        notificationAuthorized: Bool,
        isForeground: Bool
    ) {
        let previous = decisionAvailability
        let enteredForeground = isForeground && !appIsForeground
        notificationAuthorizationGranted = notificationAuthorized
        appIsForeground = isForeground
        if enteredForeground, status.isConnected, let task, pendingPing == nil {
            heartbeatTask?.cancel()
            ping(task)
        }
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
        startNetworkMonitor()
        openSocket()
    }

    func pair(using invitation: PairingInvitation) {
        historyPages = [:]
        historyErrors = [:]
        historyFromPreviousSession = []
        knownHistorySessions = [:]
        historyLastAccess = [:]
        historyMissingSince = [:]
        historyGeneration &+= 1
        pendingHistoryRequests.removeAll()
        historySessionName = nil
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
        startNetworkMonitor()
        openSocket()
    }

    func disconnect() {
        disconnect(clearPairing: true, clearSnapshot: true)
    }

    func retryNow() {
        guard pairing != nil || invitation != nil else { return }
        advanceConnectionGeneration()
        stopSocket()
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        shouldReconnect = true
        startNetworkMonitor()
        guard historyPacing.path?.allowsConnectionAttempts != false else { return }
        status = .connecting
        openSocket()
    }

    func restoreCachedSnapshot(_ cached: CachedHerdSnapshot) {
        snapshot = cached.snapshot
        lastSnapshotAt = cached.savedAt
        isShowingCachedSnapshot = true
    }

    func replaceWithLiveSnapshot(_ snapshot: SessionSnapshot, receivedAt: Date = Date()) {
        updateHistoryPaneSet(snapshot.panes, now: receivedAt)
        let terminalIDs = snapshot.panes.reduce(into: [String: String]()) { $0[$1.paneID] = $1.terminalID }
        retainedTerminalAgentIDs = retainedTerminalAgentIDs.filter { paneID, identity in
            terminalIDs[paneID] == identity.terminalID
        }
        for pane in snapshot.panes {
            if let sessionID = reportedAgentSessionID(for: pane) {
                retainedTerminalAgentIDs[pane.paneID] = (pane.terminalID, sessionID)
            }
        }
        terminalViewCache.retain(Set(snapshot.panes.map { terminalCacheKey(for: $0) }))
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
        let recovered = !status.isConnected
        status = .connected
        if recovered, let task, pendingPing == nil {
            heartbeatTask?.cancel()
            ping(task)
        }
        didReceiveSnapshot?(snapshot, receivedAt)
    }

    func restoreCachedHistory(
        _ pages: [String: TranscriptHistoryPage],
        sessionName: String,
        now: Date = Date()
    ) {
        guard historyPages.isEmpty else { return }
        let hasLiveSnapshot = snapshot != nil && !isShowingCachedSnapshot
        let livePanes = hasLiveSnapshot ? snapshot?.panes ?? [] : []
        let livePaneIDs = Set(livePanes.map(\.paneID))
        let liveSessions: [String: String] = Dictionary(
            uniqueKeysWithValues: livePanes.compactMap { pane in
                guard let beacon = pane.beacon,
                      !beacon.sessionID.isEmpty,
                      !beacon.transcriptPath.isEmpty else { return nil }
                return (pane.paneID, beacon.sessionID)
            }
        )
        historyPages = pages.filter { paneID, page in
            guard !page.agentSessionID.isEmpty else { return false }
            return liveSessions[paneID].map { $0 == page.agentSessionID } ?? true
        }
        historyFromPreviousSession = Set(historyPages.keys.filter {
            liveSessions[$0] == nil
        })
        for (paneID, page) in historyPages {
            historyLastAccess[paneID] = now
            if !page.agentSessionID.isEmpty {
                knownHistorySessions[paneID] = page.agentSessionID
            }
            if hasLiveSnapshot, !livePaneIDs.contains(paneID) {
                historyMissingSince[paneID] = now
            }
        }
        pruneHistory(now: now)
        scheduleHistoryPruneIfNeeded()
        historySessionName = sessionName
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

    func requestHistory(
        paneID: String,
        sessionID: String = "",
        beforeTurnIndex: Int? = nil,
        limit: Int = TranscriptPagination.maximumLimit
    ) {
        // Keep one request per pane in flight. sendAction uses independent
        // tasks, so FIFO reply metadata is safe only without overlap.
        guard status.isConnected, pendingHistoryRequests[paneID] == nil else { return }
        let effectiveSessionID = sessionID
        if PendingHistoryRequest.sessionChanged(
            previous: knownHistorySessions[paneID], current: effectiveSessionID
        ) {
            resetHistory(paneID: paneID, sessionID: effectiveSessionID)
        }
        knownHistorySessions[paneID] = effectiveSessionID
        let requestID = UUID().uuidString
        pendingHistoryRequests[paneID] = PendingHistoryRequest(
            generation: historyGeneration,
            replacesPage: beforeTurnIndex == nil,
            sessionName: sessionName,
            paneID: paneID,
            sessionID: effectiveSessionID,
            requestID: requestID
        )
        historyLastAccess[paneID] = Date()
        historyErrors.removeValue(forKey: paneID)
        sendAction(.history(
            paneID: paneID,
            sessionID: effectiveSessionID,
            requestID: requestID,
            beforeTurnIndex: beforeTurnIndex,
            limit: limit,
            herdSessionName: sessionName
        ))
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

    func openPane(paneID: String, cols: Int = 80, rows: Int = 24, resetStream: Bool = false) {
        activePaneID = paneID
        if resetStream {
            seededPanes.remove(paneID)
            pendingScrollback.removeValue(forKey: paneID)
            cancelScrollbackRefresh(for: paneID)
            latestGridByPaneID.removeValue(forKey: paneID)
            passwordPromptGridReader.remove(paneID)
        }
        let openID = UUID()
        paneOpenIDs[paneID] = openID
        let generation = connectionGeneration
        if desiredStreams[paneID] == nil {
            desiredStreams[paneID] = (cols, rows)
        }
        Task {
            do {
                guard paneOpenIDs[paneID] == openID, connectionGeneration == generation else { return }
                if resetStream {
                    // Complete detach before reading the seed. Otherwise the
                    // old stream's background read can be cancelled by attach.
                    try await send(.detachStream(paneID: paneID))
                    guard paneOpenIDs[paneID] == openID, connectionGeneration == generation else { return }
                }
                if hostCapabilities?.supportsIndependentPaneObservation != true {
                    // Legacy hosts require the shared selection path. New hosts
                    // can read and observe an explicit pane without changing focus.
                    try await send(.selectPane(paneID: paneID))
                    guard paneOpenIDs[paneID] == openID, connectionGeneration == generation else { return }
                    try await send(.focusPane(paneID: paneID))
                    guard paneOpenIDs[paneID] == openID, connectionGeneration == generation else { return }
                }
                // Read the size at send time, not at entry: the terminal's
                // layout often lands (and updates desiredStreams) between
                // openPane and this send, and the server drops resizes for
                // panes with no active stream — attaching with a stale size
                // would leave the stream permanently smaller than the view.
                let size = desiredStreams[paneID] ?? (cols, rows)
                if !seededPanes.contains(paneID) {
                    // Sent before attachStream: the server handles messages in
                    // order, so history arrives before the first full frame.
                    try await send(
                        .readScrollback(
                            paneID: paneID, lines: 1000, rows: size.rows, fullGrid: true,
                            knownHash: scrollbackHashes[paneID])
                    )
                }
                guard paneOpenIDs[paneID] == openID, connectionGeneration == generation else { return }
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
        if activePaneID == paneID { activePaneID = nil }
        desiredStreams.removeValue(forKey: paneID)
        paneOpenIDs.removeValue(forKey: paneID)
        latestGridByPaneID.removeValue(forKey: paneID)
        passwordPromptGridReader.remove(paneID)
        // The next view restores a hash only when it also retains the history.
        seededPanes.remove(paneID)
        scrollbackHashes.removeValue(forKey: paneID)
        cancelScrollbackRefresh(for: paneID)
        pendingScrollback.removeValue(forKey: paneID)
        let generation = connectionGeneration
        Task {
            do {
                guard desiredStreams[paneID] == nil, connectionGeneration == generation else { return }
                try await send(.detachStream(paneID: paneID))
            } catch {
                handleSocketFailure(error)
            }
        }
    }

    /// Observe frames repaint cells rather than emitting terminal line feeds.
    /// Refresh authoritative history during output, including repeated rows
    /// whose movement cannot be inferred from two identical screen images.
    private func scheduleScrollbackRefresh(for paneID: String) {
        guard status.isConnected, desiredStreams[paneID] != nil,
              paneFrameHandlers[paneID]?.isEmpty == false,
              dirtyScrollback.contains(paneID),
              scrollbackRefreshTasks[paneID] == nil,
              !scrollbackRefreshInFlight.contains(paneID) else { return }
        let generation = connectionGeneration
        scrollbackRefreshTasks[paneID] = Task { @MainActor [weak self] in
            let interval = self?.scrollbackRefreshInterval ?? 0.25
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled, let self,
                  self.connectionGeneration == generation,
                  let size = self.desiredStreams[paneID],
                  self.status.isConnected else { return }
            self.scrollbackRefreshTasks.removeValue(forKey: paneID)
            self.dirtyScrollback.remove(paneID)
            self.scrollbackRefreshInFlight.insert(paneID)
            self.historyReadStarted[paneID] = self.uptime()
            do {
                try await self.send(.readScrollback(
                    paneID: paneID, lines: 1000, rows: size.rows, fullGrid: true,
                    knownHash: self.scrollbackHashes[paneID]
                ))
            } catch {
                guard self.connectionGeneration == generation else { return }
                self.scrollbackRefreshInFlight.remove(paneID)
                self.handleSocketFailure(error)
            }
        }
    }

    private func finishScrollbackRead(paneID: String) {
        scrollbackRefreshInFlight.remove(paneID)
        if let started = historyReadStarted.removeValue(forKey: paneID) {
            historyPacing.historyReadDuration = max(0, uptime() - started)
        }
        seededPanes.insert(paneID)
    }

    private var retainedTerminalAgentIDs: [String: (terminalID: String, sessionID: String)] = [:]

    private func reportedAgentSessionID(for pane: Pane) -> String? {
        // Resume paths and hook presence can change without replacing an agent.
        // Prefer a native session ID, then retain the last observed hook ID.
        if let session = pane.agentSession, session.kind == .id, !session.value.isEmpty { return session.value }
        return (pane.beacon?.sessionID).flatMap { $0.isEmpty ? nil : $0 }
    }

    func terminalCacheKey(for pane: Pane) -> TerminalCacheKey {
        let retained = retainedTerminalAgentIDs[pane.paneID]
        let sessionID = reportedAgentSessionID(for: pane)
            ?? (retained?.terminalID == pane.terminalID ? retained?.sessionID : nil)
        return TerminalCacheKey(
            scope: terminalCacheScope, paneID: pane.paneID, terminalID: pane.terminalID,
            agentSessionID: sessionID
        )
    }

    func terminalCacheKey(paneID: String) -> TerminalCacheKey? {
        snapshot?.panes.first { $0.paneID == paneID }.map { terminalCacheKey(for: $0) }
    }

    func restoreScrollbackHash(_ hash: String?, paneID: String) {
        scrollbackHashes[paneID] = hash
    }

    private func invalidateTerminalCache() {
        terminalCacheScope = UUID()
        retainedTerminalAgentIDs.removeAll()
        terminalViewCache.removeAll()
        scrollbackHashes.removeAll()
    }

    private func cancelScrollbackRefresh(for paneID: String) {
        scrollbackRefreshTasks.removeValue(forKey: paneID)?.cancel()
        scrollbackRefreshInFlight.remove(paneID)
        historyReadStarted.removeValue(forKey: paneID)
        dirtyScrollback.remove(paneID)
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

    func closeWorkspace(workspaceID: String, expectedConnectionID: String?) {
        guard status.isConnected, let expectedConnectionID, !expectedConnectionID.isEmpty,
              expectedConnectionID == hostCapabilities?.connectionID else {
            actionError = "The workspace connection changed. Review the workspace before closing it."
            return
        }
        sendAction(.closeWorkspace(workspaceID: workspaceID, connectionID: expectedConnectionID))
    }

    func closeWorkspaceGroup(_ preview: WorkspaceClosePreview) {
        guard hostCapabilities?.supportsWorkspaceGroupClose == true, let connectionID = preview.connectionID else {
            actionError = "Group closure requires an updated Mac app and Herdr 0.9 or later."
            return
        }
        guard status.isConnected, connectionID == hostCapabilities?.connectionID else {
            actionError = "The workspace connection changed. Review the group before closing it."
            return
        }
        sendAction(.closeWorkspaceGroup(workspaceID: preview.workspaceID, expectedWorkspaceIDs: preview.workspaceIDs, connectionID: connectionID))
    }

    func manageHerdr(_ request: HerdrManagementRequest) {
        guard herdrManagementRequest == nil else { return }
        guard status.isConnected, request.connectionID == hostCapabilities?.connectionID,
              hostCapabilities?.supports(request.action) == true else {
            herdrManagementText = "The target changed or does not support this action. Review the server again."
            return
        }
        herdrManagementRequest = request
        herdrManagementText = "Running: \(request.action.title)."
        sendAction(.manageHerdr(request))
    }

    func requestAgentExplanation(paneID: String) {
        guard status.isConnected, hostCapabilities?.supportsAgentExplanation == true,
              let connectionID = hostCapabilities?.connectionID else { return }
        let request = AgentExplanation(paneID: paneID, requestID: UUID().uuidString, connectionID: connectionID)
        agentExplanation = request
        sendAction(.explainAgent(paneID: paneID, requestID: request.requestID, connectionID: connectionID))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, self.agentExplanation?.requestID == request.requestID,
                  self.agentExplanation?.text == nil else { return }
            self.agentExplanation?.text = "The explanation request timed out. Close this sheet and try again."
        }
    }

    func broadcastInput(tabID: String, text: String) {
        sendAction(.broadcastInput(tabID: tabID, text: text))
    }

    func requestMachines(_ operation: MachineOperation = .refresh) {
        guard status.isConnected else { actionError = "Connect to the Mac before managing machines."; return }
        guard hostCapabilities?.operations.contains(BridgeCapability.machineDirectory) == true else {
            actionError = "Update the Mac app to manage machines."
            return
        }
        sendAction(.machineRequest(.init(revision: machines.revision, operation: operation)))
    }

    func selectMachine(_ entry: MachineEntry) {
        guard entry.health == .online, entry == machines.entry(for: entry.endpoint) else { return }
        endpointView.close()
        selectedMachine = entry.endpoint
        pendingMachineNotification = nil
        machineNotificationRequiresSelection = false
        pendingMachineAgent = nil
        openEndpointView()
    }

    func selectMachineAgent(_ agent: MachineAgent) {
        guard let entry = machines.entry(for: agent.resource.endpoint), entry.health == .online,
              entry.agents.contains(agent) else { return }
        selectMachine(entry)
        pendingMachineAgent = agent.resource
    }

    func openMachineNotification(_ resource: MachineResource) {
        guard resource.isValidNotificationTarget else { actionError = "The machine notification target is invalid."; return }
        endpointView.close()
        selectedMachine = resource.endpoint
        pendingMachineAgent = nil
        endpointViewRequested = true
        machineNotificationRequiresSelection = true
        pendingMachineNotification = resource
        if status.isConnected { requestMachines() }
    }

    private func resolveMachineNotification() {
        guard let target = pendingMachineNotification else { return }
        guard let entry = machines.entry(for: target.endpoint) else {
            guard !machines.busy else { return }
            pendingMachineNotification = nil
            actionError = "This machine was removed. Open Machines to choose another target."
            return
        }
        guard entry.health == .online else { return }
        pendingMachineNotification = nil
        guard let agent = entry.agents.first(where: { $0.resource.paneID == target.paneID && $0.resource.bootID == target.bootID }) else {
            actionError = "This agent or server changed. Open Machines to review its current state."
            return
        }
        selectMachineAgent(agent)
    }

    func openEndpointView() {
        if endpointViewRequested, endpointView.identity != nil, endpointView.error == nil { return }
        endpointViewRequested = true
        guard status.isConnected, !machineNotificationRequiresSelection else { return }
        let identity: String
        let endpoint = selectedMachine
        if let endpoint {
            guard let entry = machines.entry(for: endpoint), entry.health == .online, let connectionID = entry.connectionID else { return }
            identity = connectionID
        } else {
            guard hostCapabilities?.operations.contains(BridgeCapability.nativeEndpoint) == true,
                  let connectionID = hostCapabilities?.connectionID else { return }
            identity = connectionID
        }
        let socket = task
        let transportGeneration = connectionGeneration
        endpointView.open(connectionID: identity, machineEndpoint: endpoint) { [weak self] request in
            guard let self, self.status.isConnected, self.connectionGeneration == transportGeneration else { throw CancellationError() }
            let current = endpoint.flatMap { self.machines.entry(for: $0)?.connectionID } ?? self.hostCapabilities?.connectionID
            let retained = self.endpointView.identity == request.identity && self.endpointView.retainsHostConnection
            guard current == identity || retained else { throw CancellationError() }
            try await self.send(.endpointRequest(request), over: socket)
        }
    }

    func closeEndpointView() {
        endpointViewRequested = false
        endpointView.close()
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
        guard cols > 0, rows > 0, desiredStreams[paneID] != nil,
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
        handler: @escaping (Data, PaneFrameKind, PaneGridSize?) -> Void
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
    func sendComposedLine(_ bytes: [UInt8], to paneID: String, expectedConnectionID: String? = nil) async -> ComposedLineSendResult {
        if let expectedConnectionID {
            guard status.isConnected, expectedConnectionID == hostCapabilities?.connectionID else {
                actionError = "The notification host changed. No reply was sent."
                return .refused
            }
        }
        switch passwordPromptState(for: paneID) {
        case .prompt:
            refusePasswordPromptSend(to: paneID)
            return .refused
        case .unknown:
            actionError = PasswordPromptGuard.waiting
            guard expectedConnectionID == nil else { return .refused }
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
                    expectedConnectionID.map { .notificationAction(.init(connectionID: $0, paneID: paneID,
                        operation: .input(bytesBase64: Data(bytes).base64EncodedString()))) }
                        ?? .input(paneID: paneID, bytesBase64: Data(bytes).base64EncodedString())
                )
                return .accepted
            } catch {
                handleSocketFailure(error)
            }
        }
        guard expectedConnectionID == nil else { return .refused }
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
        // A queued line must not restart a slow handshake or its retry delay.
        if !status.isConnected, task == nil, reconnectTask == nil,
           historyPacing.path?.allowsConnectionAttempts != false, !requiresRepair {
            retryNow()
        }
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
    func validateNotificationHost(_ expected: String, pairing: Pairing) async -> Bool {
        guard !expected.isEmpty else { return false }
        if !status.isConnected { connect(to: pairing) }
        for _ in 0..<80 {
            if status.isConnected, let current = hostCapabilities?.connectionID {
                guard current == expected,
                      hostCapabilities?.operations.contains(BridgeCapability.notificationActions) == true else {
                    actionError = "The notification host changed. Open its terminal before responding."
                    return false
                }
                return true
            }
            if requiresRepair || Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        actionError = "The notification host could not be verified."
        return false
    }

    func connectAndSendInput(
        _ bytes: [UInt8],
        to paneID: String,
        pairing: Pairing,
        expectedConnectionID: String? = nil
    ) async -> Bool {
        if let expectedConnectionID,
           !(await validateNotificationHost(expectedConnectionID, pairing: pairing)) { return false }

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
                expectedConnectionID.map { .notificationAction(.init(connectionID: $0, paneID: paneID,
                    operation: .input(bytesBase64: Data(bytes).base64EncodedString()))) }
                    ?? .input(paneID: paneID, bytesBase64: Data(bytes).base64EncodedString())
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
        pairing: Pairing,
        expectedConnectionID: String? = nil
    ) async -> Bool {
        if let expectedConnectionID,
           !(await validateNotificationHost(expectedConnectionID, pairing: pairing)) { return false }

        if expectedConnectionID != nil, outbox.contains(where: { $0.paneID == paneID }) {
            actionError = "Review the queued input before replying to this notification."
            return false
        }
        if expectedConnectionID == nil, queueNotificationReplyBehindOutboxIfNeeded(bytes, paneID: paneID) {
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
        let replyStreamGeneration = connectionGeneration
        @MainActor func detachTemporaryStream() async {
            guard attachedTemporaryStream,
                  connectionGeneration == replyStreamGeneration,
                  desiredStreams[paneID] == nil else { return }
            attachedTemporaryStream = false
            try? await send(.detachStream(paneID: paneID))
        }
        defer {
            if attachedTemporaryStream {
                Task { await detachTemporaryStream() }
            }
        }
        if passwordPromptState(for: paneID) == .unknown, desiredStreams[paneID] == nil {
            guard clock.now < deadline else {
                return replyVerificationTimedOut(bytes, paneID: paneID)
            }
            switch await attachReplyStream(to: paneID, clock: clock, deadline: deadline) {
            case .attached:
                attachedTemporaryStream = true
            case .failed:
                return false
            case .timedOut:
                return replyVerificationTimedOut(bytes, paneID: paneID)
            }
        }
        guard clock.now < deadline else {
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
            return replyVerificationTimedOut(bytes, paneID: paneID)
        }
        if expectedConnectionID != nil, outbox.contains(where: { $0.paneID == paneID }) {
            actionError = "Review the queued input before replying to this notification."
            await detachTemporaryStream()
            return false
        }
        if expectedConnectionID == nil, queueNotificationReplyBehindOutboxIfNeeded(bytes, paneID: paneID) {
            await detachTemporaryStream()
            return false
        }
        guard clock.now < deadline else {
            return replyVerificationTimedOut(bytes, paneID: paneID)
        }
        let result = await sendComposedLine(bytes, to: paneID, expectedConnectionID: expectedConnectionID)
        await detachTemporaryStream()
        return result == .accepted
    }

    private func queueNotificationReplyBehindOutboxIfNeeded(
        _ bytes: [UInt8],
        paneID: String
    ) -> Bool {
        guard outbox.contains(where: { $0.paneID == paneID }) else { return false }
        if passwordPromptState(for: paneID) == .prompt {
            refusePasswordPromptSend(to: paneID)
            return true
        }
        enqueue(bytes, to: paneID)
        return true
    }

    private func attachReplyStream(
        to paneID: String,
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) async -> ReplyAttachmentResult {
        let race = ReplyAttachmentRace()
        let generation = connectionGeneration
        let attachTask = Task { @MainActor [weak self] in
            guard let self else {
                await race.finish(with: .failed)
                return
            }
            do {
                try await send(
                    .attachStream(paneID: paneID, cols: 80, rows: 24, fullGrid: true)
                )
                let wonRace = await race.finish(with: .attached)
                if !wonRace,
                   connectionGeneration == generation,
                   desiredStreams[paneID] == nil {
                    try? await send(.detachStream(paneID: paneID))
                }
            } catch is CancellationError {
                if connectionGeneration == generation,
                   desiredStreams[paneID] == nil {
                    try? await send(.detachStream(paneID: paneID))
                }
            } catch {
                if await race.finish(with: .failed) {
                    handleSocketFailure(error)
                }
            }
        }
        let timeoutTask = Task {
            do {
                try await clock.sleep(until: deadline)
                await race.finish(with: .timedOut)
            } catch {
                // The attach completed before the deadline.
            }
        }

        let result = await race.wait()
        timeoutTask.cancel()
        if case .timedOut = result {
            attachTask.cancel()
        }
        return result
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
        pairing: Pairing,
        expectedConnectionID: String? = nil
    ) async -> Bool {
        if let expectedConnectionID,
           !(await validateNotificationHost(expectedConnectionID, pairing: pairing)) { return false }

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
                        expectedConnectionID.map { .notificationAction(.init(connectionID: $0, paneID: paneID,
                            operation: .decide(requestID: requestID, decision: decision))) }
                            ?? .decide(paneID: paneID, requestID: requestID, decision: decision),
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
        guard historyPacing.path?.allowsConnectionAttempts != false else { return }
        guard let url = webSocketURL(), shouldReconnect else {
            status = .failed(.invalidAddress(host: host))
            return
        }

        reconnectTask?.cancel()
        reconnectTask = nil
        if status.diagnosis == nil {
            status = .connecting
        }
        let socket = socketFactory(url)
        task = socket
        socket.resume()
        startHandshakeDeadline(for: socket)

        receiveTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.sendAuthentication(over: socket)
                try await self.receiveMessages(from: socket)
            } catch is CancellationError {
                return
            } catch {
                self.handleSocketFailure(error, from: socket)
            }
        }
    }

    private func sendAuthentication(over socket: any BridgeSocket) async throws {
        let client = clientInfo()
        if let invitation {
            try await send(
                .pair(
                    code: invitation.code,
                    protocolVersion: bridgeProtocolVersion,
                    client: client
                ), over: socket
            )
        } else if let pairing {
            try await send(.hello(token: pairing.token, client: client), over: socket)
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
            capabilities: decisionAvailability.capabilities + [BridgeCapability.nativeEndpoint, BridgeCapability.machineDirectory, BridgeCapability.notificationActions]
        )
    }

    private func receiveMessages(from socket: any BridgeSocket) async throws {
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
                if let paneError = TranscriptHistoryErrorRouter.consumeUnsupportedReply(
                    data: data,
                    pending: &pendingHistoryRequests
                ) {
                    historyErrors[paneError.paneID] = paneError.message
                    continue
                }
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
        case let .snapshot(snapshot, snapshotSessionName, capabilities):
            if selectedMachine == nil, !endpointView.retainsHostConnection,
               endpointView.identity?.connectionID != capabilities?.connectionID { endpointView.disconnect() }
            hostCapabilities = capabilities
            if !machineListRequested, capabilities?.operations.contains(BridgeCapability.machineDirectory) == true {
                machineListRequested = true
                requestMachines()
            }
            if let explanation = agentExplanation, explanation.connectionID != capabilities?.connectionID {
                agentExplanation?.text = "The server connection changed. Request the explanation again."
            }
            if let snapshotSessionName, sessionName != snapshotSessionName {
                invalidateTerminalCache()
                historyGeneration &+= 1
                pendingHistoryRequests.removeAll()
                historyPages = [:]
                historyErrors = [:]
                historyFromPreviousSession = []
                knownHistorySessions = [:]
                historySessionName = snapshotSessionName
                sessionName = snapshotSessionName
                didReceiveHistoryPages?(historyPages)
            }
            replaceWithLiveSnapshot(snapshot)
            if endpointViewRequested, endpointView.identity == nil { openEndpointView() }
        case let .sessions(list):
            sessions = list
            if let current = list.first(where: { $0.isCurrent }) {
                if let sessionName, sessionName != current.name {
                    invalidateTerminalCache()
                    historyGeneration &+= 1
                    historyPages = [:]
                    historyErrors = [:]
                    historyFromPreviousSession = []
                    knownHistorySessions = [:]
                    historySessionName = current.name
                    didReceiveHistoryPages?(historyPages)
                }
                sessionName = current.name
            }
        case let .backgroundWork(work):
            didReceiveBackgroundWork?(work)
        case let .historyPage(page):
            guard let request = pendingHistoryRequests[page.paneID],
                  request.matches(page) else { return }
            pendingHistoryRequests.removeValue(forKey: page.paneID)
            guard request.generation == historyGeneration,
                  page.herdSessionName == nil || page.herdSessionName == request.sessionName
            else { return }
            mergeHistoryPage(
                page,
                replacing: request.replacesPage
            )
            sendAction(.historyReceived(
                paneID: page.paneID,
                sessionID: page.agentSessionID,
                requestID: page.requestID,
                herdSessionName: page.herdSessionName,
                throughTurnIndex: page.turns.last?.index
            ))
        case let .historyError(paneID, sessionID, requestID, message):
            guard let paneError = TranscriptHistoryErrorRouter.consume(
                pending: &pendingHistoryRequests,
                paneID: paneID,
                sessionID: sessionID,
                requestID: requestID,
                message: message
            ) else { return }
            historyErrors[paneError.paneID] = paneError.message
        case let .pushPrefsState(preferences):
            pushPreferences = preferences
            supportsPushPreferences = true
            if pendingPushPreferences?.effective(at: Date()) == preferences {
                clearPendingPushPreferences()
            } else if pendingPushPreferences == nil {
                synchronizePushPreferencesTimeZone()
            }
        case let .paneFrame(paneID, bytesBase64, full, seq, cols, rows):
            guard let data = Data(base64Encoded: bytesBase64) else { return }
            if full && seq <= 1 {
                // A restarted observe stream cancels its pending server read.
                // Its first frame must release the old request slot.
                cancelScrollbackRefresh(for: paneID)
            }
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
            let kind: PaneFrameKind = full ? (seq == 0 ? .preview : .full) : .delta
            for handler in handlers {
                handler(data, kind, grid)
            }
            dirtyScrollback.insert(paneID)
            scheduleScrollbackRefresh(for: paneID)
        case let .scrollbackUnchanged(paneID, contentHash):
            guard desiredStreams[paneID] != nil else { return }
            finishScrollbackRead(paneID: paneID)
            if scrollbackHashes[paneID] != contentHash {
                // A discarded view cannot validate an unchanged reply.
                scrollbackHashes.removeValue(forKey: paneID)
                seededPanes.remove(paneID)
                dirtyScrollback.insert(paneID)
            }
            scheduleScrollbackRefresh(for: paneID)
        case let .scrollback(paneID, bytesBase64):
            // A reply already queued by the Mac can outlive local detach.
            // Do not let it seed a later visit or reach the outgoing view.
            guard desiredStreams[paneID] != nil else { return }
            finishScrollbackRead(paneID: paneID)
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
            scrollbackHashes[paneID] = PaneScrollback.contentHash(data)
            scheduleScrollbackRefresh(for: paneID)
            guard let handlers = paneScrollbackHandlers[paneID]?.values,
                  !handlers.isEmpty else {
                pendingScrollback[paneID] = data
                return
            }
            for handler in handlers {
                handler(data)
            }
        case let .error(message, code, detail, paneID, requestID):
            endpointView.receiveError(message, requestID: requestID)
            if let requestID, requestID == herdrManagementRequest?.id {
                herdrManagementText = detail ?? message
                herdrManagementRequest = nil
            }
            // Older Macs send a pong and then this exact error for the same ping.
            // No application operation uses a non-text frame.
            if hasSentPing, status.isConnected, code == .invalidRequest,
               message == "Only WebSocket text frames are supported.",
               detail == "The bridge accepts WebSocket text frames only." {
                return
            }
            if code == .scrollbackUnavailable, let failedPane = paneID ?? detail {
                scrollbackRefreshInFlight.remove(failedPane)
                historyReadStarted.removeValue(forKey: failedPane)
                // Preserve output received during the failed read. The next
                // request consumes that flag, so an idle failure cannot loop.
                scheduleScrollbackRefresh(for: failedPane)
            }
            let historyMessage = code == .unknownMessage
                ? "History is not supported by this Mac."
                : detail ?? message
            let connectionLevel = code.map {
                BridgeErrorPolicy.isConnectionLevel($0, phase: .operation)
            } ?? false
            if let paneError = TranscriptHistoryErrorRouter.consumeError(
                pending: &pendingHistoryRequests,
                paneID: paneID,
                requestID: requestID,
                allowPaneOnly: !connectionLevel,
                message: historyMessage
            ) {
                historyErrors[paneError.paneID] = paneError.message
                if !connectionLevel { return }
            }
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
            } else if Self.isActionError(message)
                || (status.isConnected && !ConnectionDiagnosis.isHerdUnavailable(message)) {
                // Legacy Macs omit error codes. An unknown operation error is
                // not evidence that the authenticated transport has failed.
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
        case let .agentExplanation(response):
            if agentExplanation?.accepts(response, connectionID: hostCapabilities?.connectionID) == true {
                agentExplanation = response
            }
        case let .machineState(state):
            machines = state
            resolveMachineNotification()
            if let endpoint = selectedMachine,
               state.entry(for: endpoint)?.connectionID != endpointView.identity?.connectionID {
                endpointView.disconnect()
                pendingMachineAgent = nil
            }
            if endpointViewRequested, endpointView.identity == nil { openEndpointView() }
        case let .endpointState(state):
            endpointView.receive(state)
            if let target = pendingMachineAgent, !endpointView.busy, let snapshot = endpointView.state?.snapshot {
                pendingMachineAgent = nil
                if state.identity.machineEndpoint == target.endpoint,
                   state.identity.connectionID == target.connectionID, snapshot.bootID == target.bootID {
                    endpointView.command(.focusPane(target.paneID))
                } else { actionError = "The agent changed. Select it again from Machines." }
            }
        case let .herdrManagementResult(result):
            // Handoff changes the server identity. Match the original request,
            // and report its result without applying it to the new server state.
            if herdrManagementRequest == result.request {
                herdrManagementText = result.text
                herdrManagementRequest = nil
            }
        case .event:
            break
        case .pair, .hello, .subscribe, .attachStream, .detachStream,
             .input, .sendImage, .focusPane, .selectPane, .resizePane,
             .launchAgent, .renamePane, .renameTab, .closePane, .closeTab,
             .registerPush, .unregisterPush, .readScrollback,
             .renameWorkspace, .closeWorkspace, .closeWorkspaceGroup, .broadcastInput, .sendKeys,
             .decide, .decisionAvailability, .listSessions, .selectSession,
             .history, .historyReceived, .pushPrefs, .explainAgent, .manageHerdr, .endpointRequest, .machineRequest, .notificationAction:
            break
        }
    }

    private func mergeHistoryPage(_ page: TranscriptHistoryPage, replacing: Bool) {
        guard !page.agentSessionID.isEmpty else {
            historyPages.removeValue(forKey: page.paneID)
            historyErrors.removeValue(forKey: page.paneID)
            historyFromPreviousSession.remove(page.paneID)
            knownHistorySessions.removeValue(forKey: page.paneID)
            historyLastAccess.removeValue(forKey: page.paneID)
            didReceiveHistoryPages?(historyPages)
            return
        }
        let existing = historyPages[page.paneID]
        let continuesSession = !replacing
            && existing?.agentSessionID == page.agentSessionID
        var byIndex = Dictionary(
            uniqueKeysWithValues: (continuesSession ? existing?.turns ?? [] : []).map {
                ($0.index, $0)
            }
        )
        for turn in page.turns { byIndex[turn.index] = turn }
        let turns = byIndex.values.sorted { $0.index < $1.index }
        historyPages[page.paneID] = TranscriptHistoryPage(
            paneID: page.paneID,
            sessionID: page.sessionID,
            resolvedSessionID: page.resolvedSessionID,
            requestID: page.requestID,
            herdSessionName: page.herdSessionName,
            turns: turns,
            hasMore: page.hasMore,
            sinceLastSeen: continuesSession
                ? existing?.sinceLastSeen ?? page.sinceLastSeen
                : page.sinceLastSeen,
            state: page.state
        )
        historyLastAccess[page.paneID] = Date()
        historyFromPreviousSession.remove(page.paneID)
        if !page.agentSessionID.isEmpty {
            knownHistorySessions[page.paneID] = page.agentSessionID
        }
        historyErrors.removeValue(forKey: page.paneID)
        pruneHistory()
        didReceiveHistoryPages?(historyPages)
    }

    private func updateHistoryPaneSet(_ panes: [Pane], now: Date) {
        let livePaneIDs = Set(panes.map(\.paneID))
        for pane in panes {
            guard let beacon = pane.beacon,
                  !beacon.transcriptPath.isEmpty,
                  !beacon.sessionID.isEmpty else {
                if !historyFromPreviousSession.contains(pane.paneID),
                   (historyPages[pane.paneID] != nil
                    || knownHistorySessions[pane.paneID] != nil) {
                    resetHistory(paneID: pane.paneID, sessionID: "")
                }
                historyMissingSince.removeValue(forKey: pane.paneID)
                continue
            }
            let sessionID = beacon.sessionID
            if historyFromPreviousSession.contains(pane.paneID) {
                if historyPages[pane.paneID]?.agentSessionID == sessionID {
                    historyFromPreviousSession.remove(pane.paneID)
                } else {
                    resetHistory(paneID: pane.paneID, sessionID: sessionID)
                }
            } else if PendingHistoryRequest.sessionChanged(
                previous: knownHistorySessions[pane.paneID], current: sessionID
            ) {
                resetHistory(paneID: pane.paneID, sessionID: sessionID)
            }
            if !sessionID.isEmpty { knownHistorySessions[pane.paneID] = sessionID }
            historyMissingSince.removeValue(forKey: pane.paneID)
        }
        for paneID in trackedHistoryPaneIDs where !livePaneIDs.contains(paneID) {
            historyMissingSince[paneID] = historyMissingSince[paneID] ?? now
        }
        pruneHistory(now: now)
        scheduleHistoryPruneIfNeeded()
    }

    private func resetHistory(paneID: String, sessionID: String) {
        pendingHistoryRequests.removeValue(forKey: paneID)
        historyPages.removeValue(forKey: paneID)
        historyErrors.removeValue(forKey: paneID)
        historyLastAccess.removeValue(forKey: paneID)
        historyFromPreviousSession.remove(paneID)
        if sessionID.isEmpty {
            knownHistorySessions.removeValue(forKey: paneID)
        } else {
            knownHistorySessions[paneID] = sessionID
        }
        didReceiveHistoryPages?(historyPages)
    }

    var trackedHistoryPaneIDs: Set<String> {
        TranscriptHistoryRetentionPolicy.trackedPaneIDs(
            pages: Set(historyPages.keys),
            errors: Set(historyErrors.keys),
            pending: Set(pendingHistoryRequests.keys),
            sessions: Set(knownHistorySessions.keys),
            access: Set(historyLastAccess.keys),
            previousSessions: historyFromPreviousSession
        )
    }

    func pruneHistory(now: Date = Date()) {
        var changed = false
        if let activePaneID, let page = historyPages[activePaneID] {
            let trimmed = TranscriptHistoryRetentionPolicy.trimmingOldestTurns(
                page,
                maximumBytes: TranscriptHistoryRetentionPolicy.maximumBytes
            )
            if trimmed != page {
                historyPages[activePaneID] = trimmed
                changed = true
            }
        }
        let protectedPaneID = activePaneID.flatMap {
            historyPages[$0] == nil ? nil : $0
        }
        let evictions = TranscriptHistoryRetentionPolicy.evictions(
            pages: historyPages,
            lastAccess: historyLastAccess,
            missingSince: historyMissingSince,
            now: now,
            protectedPaneID: protectedPaneID
        )
        guard !evictions.isEmpty else {
            if changed { didReceiveHistoryPages?(historyPages) }
            return
        }
        for paneID in evictions {
            historyPages.removeValue(forKey: paneID)
            historyErrors.removeValue(forKey: paneID)
            historyFromPreviousSession.remove(paneID)
            pendingHistoryRequests.removeValue(forKey: paneID)
            knownHistorySessions.removeValue(forKey: paneID)
            historyLastAccess.removeValue(forKey: paneID)
            historyMissingSince.removeValue(forKey: paneID)
        }
        didReceiveHistoryPages?(historyPages)
    }

    private func scheduleHistoryPruneIfNeeded() {
        guard !historyMissingSince.isEmpty else {
            historyPruneTask?.cancel()
            historyPruneTask = nil
            return
        }
        guard historyPruneTask == nil else { return }
        historyPruneTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(
                TranscriptHistoryRetentionPolicy.closedPaneGrace
            ))
            guard let self, !Task.isCancelled else { return }
            self.historyPruneTask = nil
            self.pruneHistory()
            self.scheduleHistoryPruneIfNeeded()
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
        handshakeDeadline?.cancel()
        handshakeDeadline = nil
        // A welcome starts a new authenticated screen generation. This also
        // invalidates prompt controls and any password grid from the old socket.
        advanceConnectionGeneration()
        historyGeneration &+= 1
        pendingHistoryRequests.removeAll()
        self.sessionName = sessionName
        if let historySessionName, let sessionName,
           historySessionName != sessionName {
            invalidateTerminalCache()
            historyPages = [:]
            historyFromPreviousSession = []
            didReceiveHistoryPages?(historyPages)
        }
        self.historySessionName = sessionName
        reconnectAttempt = 0
        status = .connected
        if let task { ping(task) }
        let generation = connectionGeneration
        let socket = task
        let streamsToRestore = desiredStreams
        let openIDsToRestore = paneOpenIDs
        Task { [weak self] in
            guard let self, self.connectionGeneration == generation else { return }
            do {
                try await self.send(.subscribe, over: socket)
                guard self.connectionGeneration == generation else { return }
                if let pending = self.pendingPushPreferences {
                    try await self.send(.pushPrefs(pending), over: socket)
                }
                guard self.connectionGeneration == generation else { return }
                self.didConnect?()
                self.requestSessions()
                self.flushOutbox()
                for (paneID, size) in streamsToRestore {
                    guard self.connectionGeneration == generation else { return }
                    let openID = openIDsToRestore[paneID]
                    guard self.desiredStreams[paneID] != nil,
                          self.paneOpenIDs[paneID] == openID else { continue }
                    let needsSeed = !self.seededPanes.contains(paneID)
                    if needsSeed {
                        try await self.send(
                            .readScrollback(
                                paneID: paneID,
                                lines: 1000,
                                rows: size.rows,
                                fullGrid: true,
                                knownHash: self.scrollbackHashes[paneID]
                            ), over: socket
                        )
                    }
                    guard self.connectionGeneration == generation else { return }
                    guard self.desiredStreams[paneID] != nil,
                          self.paneOpenIDs[paneID] == openID else { continue }
                    try await self.send(
                        .attachStream(
                            paneID: paneID,
                            cols: size.cols,
                            rows: size.rows,
                            fullGrid: true
                        ), over: socket
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
        invalidateTerminalCache()
        historyGeneration &+= 1
        historyPages = [:]
        historyErrors = [:]
        historyFromPreviousSession = []
        knownHistorySessions = [:]
        historySessionName = name
        sessionName = name
        didReceiveHistoryPages?(historyPages)
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
            pendingHistoryRequests.removeAll()
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
        stopSocket()
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

    private func send(
        _ message: BridgeMessage, over expectedSocket: (any BridgeSocket)? = nil
    ) async throws {
        if let messageSender {
            try await messageSender(message)
            return
        }
        guard let socket = expectedSocket ?? task else { throw URLError(.notConnectedToInternet) }
        guard task === socket else { throw CancellationError() }
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
        do {
            try await socket.send(.string(text))
        } catch {
            guard task === socket else { throw CancellationError() }
            throw error
        }
        // A successful input send stays successful even if the socket changes
        // before this continuation resumes. Requeueing it can duplicate a line.
        if case .input = message { return }
        guard task === socket else { throw CancellationError() }
    }

    private func sendDecision(
        _ message: BridgeMessage,
        over socket: any BridgeSocket
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
        from socket: (any BridgeSocket)? = nil
    ) {
        guard !(error is CancellationError) else { return }
        if let socket, task !== socket {
            resolveDecisions(for: socket, accepted: false)
            return
        }
        if let socket = socket ?? task {
            resolveDecisions(for: socket, accepted: false)
        } else {
            resolveAllDecisions(accepted: false)
        }
        guard shouldReconnect else { return }
        scheduleReconnect(after: error)
    }

    func scheduleReconnect(
        after error: Error,
        diagnosis: ConnectionDiagnosis? = nil
    ) {
        NSLog("rai-ios: connection lost, will reconnect: %@", String(describing: error))
        guard reconnectTask == nil || reconnectTask?.isCancelled == true else { return }
        advanceConnectionGeneration()
        stopSocket()
        reconnectAttempt += 1
        status = .failed(diagnosis ?? .transport(error, host: host))
        guard historyPacing.path?.allowsConnectionAttempts != false else { return }
        let delay = min(networkTiming.reconnectBase * pow(2.0, Double(min(reconnectAttempt - 1, 5))), 30)
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
        stopSocket(closeCode: .policyViolation)
        stopNetworkMonitor()
        reconnectTask?.cancel()
        reconnectTask = nil
        status = .failed(diagnosis)
        resolveAllDecisions(accepted: false)
    }

    private func disconnect(clearPairing: Bool, clearSnapshot: Bool) {
        advanceConnectionGeneration()
        resolveAllDecisions(accepted: false)
        shouldReconnect = false
        stopSocket()
        stopNetworkMonitor()
        reconnectTask?.cancel()
        reconnectTask = nil
        status = .disconnected
        supportsPushPreferences = false
        if clearSnapshot {
            invalidateTerminalCache()
            snapshot = nil
            lastSnapshotAt = nil
            decisionBeaconReceivedAt.removeAll()
            isShowingCachedSnapshot = false
            historyPages = [:]
            historyErrors = [:]
            historyFromPreviousSession = []
            knownHistorySessions = [:]
            historyLastAccess = [:]
            historyMissingSince = [:]
            historyPruneTask?.cancel()
            historyPruneTask = nil
            activePaneID = nil
            historyGeneration &+= 1
            pendingHistoryRequests.removeAll()
            historySessionName = nil
        }
        sessionName = nil
        hostCapabilities = nil
        machineListRequested = false
        machines = MachineDirectoryState()
        pendingMachineAgent = nil
        agentExplanation?.text = "The connection closed. Request the explanation after reconnecting."
        didReceiveBackgroundWork?([])
        desiredStreams.removeAll()
        paneOpenIDs.removeAll()
        scrollbackHashes.removeAll()
        seededPanes.removeAll()
        if clearPairing {
            pendingMachineNotification = nil
            machineNotificationRequiresSelection = false
            selectedMachine = nil
            endpointViewRequested = false
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

    private func resolveDecisions(for socket: any BridgeSocket, accepted: Bool) {
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
        for task in scrollbackRefreshTasks.values { task.cancel() }
        scrollbackRefreshTasks.removeAll()
        scrollbackRefreshInFlight.removeAll()
        historyReadStarted.removeAll()
        dirtyScrollback.removeAll()
        seededPanes.removeAll()
        // The view may not have applied a received history reply yet. Its
        // pending data is invalidated below, so reconnect must request a seed.
        scrollbackHashes.removeAll()
        pendingScrollback.removeAll()
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

extension BridgeConnection {
    private func startNetworkMonitor() {
        guard monitorsNetwork, messageSender == nil, pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        let id = UUID()
        pathMonitor = monitor
        pathMonitorID = id
        monitor.pathUpdateHandler = { [weak self] path in
            let state = BridgeNetworkPath(path)
            Task { @MainActor [weak self] in
                guard let self, self.pathMonitorID == id else { return }
                self.networkPathChanged(state)
            }
        }
        monitor.start(queue: DispatchQueue(label: "rai.bridge.network-path"))
    }

    private func stopNetworkMonitor() {
        pathMonitorID = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        historyPacing = BridgeHistoryPacing()
    }

    func networkPathChanged(_ path: BridgeNetworkPath) {
        let previous = historyPacing.path
        historyPacing.path = path
        guard shouldReconnect else { return }
        if !path.allowsConnectionAttempts {
            guard previous?.allowsConnectionAttempts != false else { return }
            advanceConnectionGeneration()
            stopSocket()
            reconnectTask?.cancel()
            reconnectTask = nil
            status = .failed(.transport(URLError(.notConnectedToInternet), host: host))
        } else if previous?.allowsConnectionAttempts == false
            || (previous?.status == .satisfied && path.status == .satisfied
                && previous?.interfaces != path.interfaces) {
            // A Wi-Fi/cellular handoff cannot migrate the existing TCP socket.
            retryNow()
        }
    }

    private func stopSocket(closeCode: URLSessionWebSocketTask.CloseCode = .goingAway) {
        endpointView.disconnect()
        machineListRequested = false
        pendingMachineAgent = nil
        for index in machines.entries.indices {
            machines.entries[index].connectionID = nil
            if machines.entries[index].health != .disabled { machines.entries[index].health = .disconnected }
        }
        if herdrManagementRequest != nil {
            herdrManagementText = "The connection closed before the result arrived. The Mac may still complete the action. Check its server status."
            herdrManagementRequest = nil
        }
        if snapshot != nil { isShowingCachedSnapshot = true }
        handshakeDeadline?.cancel()
        handshakeDeadline = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        pongDeadline?.cancel()
        pongDeadline = nil
        pendingPing = nil
        hasSentPing = false
        if let socket = task {
            task = nil
            resolveDecisions(for: socket, accepted: false)
            socket.cancel(with: closeCode, reason: nil)
        }
        receiveTask?.cancel()
        receiveTask = nil
    }

    private func startHandshakeDeadline(for socket: any BridgeSocket) {
        let timeout = networkTiming.handshakeTimeout
        handshakeDeadline = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let self, self.task === socket,
                  !self.status.isConnected else { return }
            self.handleSocketFailure(URLError(.timedOut), from: socket)
        }
    }

    private func ping(_ socket: any BridgeSocket) {
        guard task === socket, status.isConnected, pendingPing == nil else { return }
        let id = UUID()
        pendingPing = id
        hasSentPing = true
        let started = uptime()
        let timeout = networkTiming.pongTimeout
        pongDeadline = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let self, self.pendingPing == id,
                  self.task === socket else { return }
            self.handleSocketFailure(URLError(.timedOut), from: socket)
        }
        socket.sendPing { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.task === socket, self.pendingPing == id else { return }
                self.pongDeadline?.cancel()
                self.pongDeadline = nil
                self.pendingPing = nil
                if let error {
                    self.handleSocketFailure(error, from: socket)
                    return
                }
                self.historyPacing.roundTrip = max(0, self.uptime() - started)
                let interval = self.networkTiming.pingInterval
                self.heartbeatTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(interval))
                    guard !Task.isCancelled else { return }
                    self?.ping(socket)
                }
            }
        }
    }
}

struct PendingHistoryRequest {
    let generation: UInt
    let replacesPage: Bool
    let sessionName: String?
    let paneID: String
    let sessionID: String
    let requestID: String

    func matches(_ page: TranscriptHistoryPage) -> Bool {
        matches(
            paneID: page.paneID,
            sessionID: page.sessionID,
            requestID: page.requestID
        )
    }

    func matches(paneID: String, sessionID: String, requestID: String) -> Bool {
        self.paneID == paneID
            && self.sessionID == sessionID
            && self.requestID == requestID
    }

    static func sessionChanged(previous: String?, current: String) -> Bool {
        guard let previous, !current.isEmpty else { return false }
        return previous != current
    }
}

struct TranscriptHistoryRetentionPolicy {
    static let maximumPanes = 8
    static let maximumBytes = 16 * 1_024 * 1_024
    static let closedPaneGrace: TimeInterval = 30

    static func trackedPaneIDs(
        pages: Set<String>,
        errors: Set<String>,
        pending: Set<String>,
        sessions: Set<String>,
        access: Set<String>,
        previousSessions: Set<String>
    ) -> Set<String> {
        pages.union(errors)
            .union(pending)
            .union(sessions)
            .union(access)
            .union(previousSessions)
    }

    static func evictions(
        pages: [String: TranscriptHistoryPage],
        lastAccess: [String: Date],
        missingSince: [String: Date],
        now: Date,
        protectedPaneID: String? = nil,
        maximumPanes: Int = maximumPanes,
        maximumBytes: Int = maximumBytes,
        closedPaneGrace: TimeInterval = closedPaneGrace
    ) -> Set<String> {
        var evicted = Set(missingSince.compactMap { paneID, missingAt in
            paneID != protectedPaneID
                && now.timeIntervalSince(missingAt) >= closedPaneGrace ? paneID : nil
        })
        let retained = pages.keys.filter {
            !evicted.contains($0) && $0 != protectedPaneID
        }.sorted {
            (lastAccess[$0] ?? .distantPast) > (lastAccess[$1] ?? .distantPast)
        }
        var bytes = protectedPaneID.flatMap { estimatedBytes(pages[$0]) } ?? 0
        var count = protectedPaneID.flatMap { pages[$0] } == nil ? 0 : 1
        for paneID in retained {
            let pageBytes = estimatedBytes(pages[paneID])
            if count >= maximumPanes || bytes + pageBytes > maximumBytes {
                evicted.insert(paneID)
            } else {
                bytes += pageBytes
                count += 1
            }
        }
        return evicted
    }

    static func trimmingOldestTurns(
        _ page: TranscriptHistoryPage,
        maximumBytes: Int
    ) -> TranscriptHistoryPage {
        var turns = page.turns
        while !turns.isEmpty, estimatedBytes(page, turns: turns) > maximumBytes {
            turns.removeFirst()
        }
        guard turns.count != page.turns.count else { return page }
        return TranscriptHistoryPage(
            paneID: page.paneID,
            sessionID: page.sessionID,
            resolvedSessionID: page.resolvedSessionID,
            requestID: page.requestID,
            herdSessionName: page.herdSessionName,
            turns: turns,
            hasMore: true,
            sinceLastSeen: page.sinceLastSeen,
            state: page.state
        )
    }

    static func estimatedBytes(_ page: TranscriptHistoryPage?) -> Int {
        guard let page else { return 0 }
        return estimatedBytes(page, turns: page.turns)
    }

    private static func estimatedBytes(
        _ page: TranscriptHistoryPage,
        turns: [TranscriptTurn]
    ) -> Int {
        let identityBytes = page.paneID.utf8.count + page.sessionID.utf8.count
        let turnBytes = turns.reduce(0) { total, turn in
            let toolNameBytes = turn.tool?.name.utf8.count ?? 0
            let toolSummaryBytes = turn.tool?.summary.utf8.count ?? 0
            return total + turn.text.utf8.count + toolNameBytes + toolSummaryBytes + 64
        }
        return identityBytes + turnBytes
    }
}

struct TranscriptHistoryErrorRouter {
    private struct ReplyEnvelope: Decodable {
        let type: String
        let paneID: String
        let sessionID: String
        let requestID: String
    }

    static func consumeUnsupportedReply(
        data: Data,
        pending: inout [String: PendingHistoryRequest]
    ) -> (paneID: String, message: String)? {
        guard let reply = try? JSONDecoder().decode(ReplyEnvelope.self, from: data),
              reply.type == "historyPage" || reply.type == "historyError",
              let request = pending[reply.paneID],
              request.matches(
                  paneID: reply.paneID,
                  sessionID: reply.sessionID,
                  requestID: reply.requestID
              ) else { return nil }
        pending.removeValue(forKey: reply.paneID)
        return (reply.paneID, "Unsupported history reply.")
    }

    static func consume(
        pending: inout [String: PendingHistoryRequest],
        paneID: String,
        sessionID: String,
        requestID: String,
        message: String
    ) -> (paneID: String, message: String)? {
        guard let request = pending[paneID], request.matches(
            paneID: paneID, sessionID: sessionID, requestID: requestID
        ) else { return nil }
        pending.removeValue(forKey: paneID)
        return (paneID, message)
    }

    static func consumeError(
        pending: inout [String: PendingHistoryRequest],
        paneID: String?,
        requestID: String?,
        allowPaneOnly: Bool,
        message: String
    ) -> (paneID: String, message: String)? {
        if let requestID {
            guard let match = pending.first(where: {
                $0.value.requestID == requestID
                    && (paneID == nil || $0.value.paneID == paneID)
            }) else { return nil }
            pending.removeValue(forKey: match.key)
            return (match.key, message)
        }
        guard allowPaneOnly, let paneID, pending.removeValue(forKey: paneID) != nil else {
            return nil
        }
        return (paneID, message)
    }
}
