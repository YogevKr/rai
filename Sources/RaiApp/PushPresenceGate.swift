import Combine
import CoreGraphics
import Foundation
import RaiCore

/// Presence-aware phone pushes: when the user is at the Mac, the Mac's own
/// notification is enough — the phone buzzing in their pocket for a pane two
/// windows away is noise. A push born while the user is active is HELD; a
/// held push polls, dies quietly if the pane gets handled at the desk, and
/// fires only if the pane still wants attention after the user goes idle.
enum HeldPushDecision: Equatable {
    case push
    case cancel
    case wait

    /// `paneStatus` is the pane's CURRENT status (nil when the pane is gone);
    /// `expectedStatus` is the one the push was created for.
    static func evaluate(
        paneStatus: AgentStatus?,
        expectedStatus: AgentStatus,
        isSelectedOnMac: Bool,
        idleSeconds: TimeInterval,
        awayAfter: TimeInterval
    ) -> HeldPushDecision {
        guard let paneStatus, paneStatus == expectedStatus else { return .cancel }
        if isSelectedOnMac { return .cancel }
        return idleSeconds >= awayAfter ? .push : .wait
    }
}

enum PushPreferenceDecision: Equatable {
    case allow
    case kindDisabled
    case snoozed
    case doNotDisturb
}

enum PushPreferenceGate {
    static func suppressesHeldEvent(
        status: AgentStatus,
        occurredAt: Date,
        preferences: PushPreferences,
        calendar: Calendar = .current
    ) -> Bool {
        var quietPreferences = preferences
        quietPreferences.kinds = .init()
        let decision = evaluate(
            status: status,
            occurredAt: occurredAt,
            preferences: quietPreferences,
            now: occurredAt,
            calendar: calendar
        )
        return decision == .snoozed || decision == .doNotDisturb
    }

    static func evaluate(
        status: AgentStatus,
        occurredAt: Date,
        preferences: PushPreferences,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> PushPreferenceDecision {
        switch status {
        case .blocked where !preferences.kinds.needsYou:
            return .kindDisabled
        case .done where !preferences.kinds.finished:
            return .kindDisabled
        case .blocked, .done:
            break
        default:
            return .kindDisabled
        }

        if let snoozeUntil = preferences.snoozeUntil,
           occurredAt < snoozeUntil || now < snoozeUntil {
            return .snoozed
        }
        if let dnd = preferences.dnd,
           dnd.contains(occurredAt, calendar: calendar)
            || dnd.contains(now, calendar: calendar) {
            return .doNotDisturb
        }
        return .allow
    }
}

struct PhonePushEvent: Equatable, Sendable {
    let paneID: String
    let paneName: String
    let workspaceID: String
    let workspaceName: String
    let status: AgentStatus
    let notificationBody: String?
    let allowsRemoteActions: Bool?
    let occurredAt: Date
    let suppressedDeviceIDs: Set<String>

    init(
        paneID: String,
        paneName: String,
        workspaceID: String,
        workspaceName: String,
        status: AgentStatus,
        notificationBody: String? = nil,
        allowsRemoteActions: Bool? = nil,
        occurredAt: Date,
        suppressedDeviceIDs: Set<String> = []
    ) {
        self.paneID = paneID
        self.paneName = paneName
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.status = status
        self.notificationBody = notificationBody
        self.allowsRemoteActions = allowsRemoteActions
        self.occurredAt = occurredAt
        self.suppressedDeviceIDs = suppressedDeviceIDs
    }
}

struct PhonePushBurst: Equatable, Sendable {
    let events: [PhonePushEvent]

    var isSummary: Bool { events.count > 1 }

    var title: String {
        guard isSummary else { return events[0].paneName }
        // The product copy intentionally covers blocked and done events with
        // one triage-focused summary. The pane list shows the current details.
        return "\(events.count) agents need you"
    }

    var body: String {
        guard isSummary else {
            return events[0].notificationBody
                ?? (events[0].status == .blocked ? "Needs you" : "Finished")
        }
        return events.map(\.paneName).joined(separator: ", ")
    }

    var paneID: String? { isSummary ? nil : events[0].paneID }
    var requiresAttention: Bool {
        !isSummary && (events[0].allowsRemoteActions ?? (events[0].status == .blocked))
    }
    var notificationIDs: [String] {
        events.map { PushNotificationIdentity.pane($0.paneID) }
    }

    var workspaceID: String? {
        let values = Set(events.map(\.workspaceID))
        return values.count == 1 ? values.first : nil
    }

    var workspaceName: String? {
        let values = Set(events.map(\.workspaceName))
        return values.count == 1 ? values.first : nil
    }

    var threadID: String {
        workspaceID ?? "rai-triage"
    }

    var summaryArgument: String {
        workspaceName ?? "rai"
    }

    var occurredAt: Date {
        events.map(\.occurredAt).max() ?? .distantPast
    }
}

enum PushBurstPlanner {
    /// Keeps stable identifier arrays well below APNs' 4,096-byte limit.
    static let maximumEventsPerPush = 32

    /// Groups consecutive events while each event remains inside the window
    /// that starts at the prior event.
    static func plan(
        events: [PhonePushEvent],
        window: TimeInterval
    ) -> [PhonePushBurst] {
        guard !events.isEmpty else { return [] }
        let ordered = events.enumerated().sorted {
            if $0.element.occurredAt == $1.element.occurredAt {
                return $0.offset < $1.offset
            }
            return $0.element.occurredAt < $1.element.occurredAt
        }.map(\.element)

        var groups: [[PhonePushEvent]] = [[ordered[0]]]
        for event in ordered.dropFirst() {
            let previous = groups[groups.count - 1].last!
            if event.occurredAt.timeIntervalSince(previous.occurredAt) <= window {
                groups[groups.count - 1].append(event)
            } else {
                groups.append([event])
            }
        }
        return groups.flatMap { group in
            stride(from: 0, to: group.count, by: maximumEventsPerPush).map { offset in
                PhonePushBurst(events: Array(
                    group[offset..<min(offset + maximumEventsPerPush, group.count)]
                ))
            }
        }
    }
}

enum NotifiedPaneStore {
    private static let key = "pushNotifiedPaneStatuses"

    static func load(defaults: UserDefaults = .standard) -> [String: AgentStatus] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: AgentStatus].self, from: data)) ?? [:]
    }

    static func save(
        _ statuses: [String: AgentStatus],
        defaults: UserDefaults = .standard
    ) {
        if statuses.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(statuses) {
            defaults.set(data, forKey: key)
        }
    }
}

enum NotificationRetractionPlanner {
    static func paneIDs(
        notifiedStatuses: [String: AgentStatus],
        currentStatuses: [String: AgentStatus],
        selectedPaneID: String?
    ) -> Set<String> {
        Set(notifiedStatuses.compactMap { paneID, notifiedStatus in
            if paneID == selectedPaneID || currentStatuses[paneID] != notifiedStatus {
                paneID
            } else {
                nil
            }
        })
    }
}

@MainActor
final class PushPresenceStatus: ObservableObject {
    static let shared = PushPresenceStatus()

    @Published private(set) var pendingCount = 0
    @Published private(set) var isAway = false

    func update(pendingCount: Int, isAway: Bool) {
        self.pendingCount = pendingCount
        self.isAway = isAway
    }
}

enum UserPresence {
    /// User counts as away after this much input silence.
    static let awayAfter: TimeInterval = 120
    /// Held pushes re-check on this cadence.
    static let pollInterval: TimeInterval = 15
    /// A single gate worker waits this long after the newest event. Events in
    /// this interval become one phone push instead of several alerts.
    static let burstWindow: TimeInterval = 15

    /// Seconds since the user last touched keyboard or mouse, session-wide.
    /// Minimum across concrete event types — the kCGAnyInputEventType trick
    /// isn't representable in Swift's CGEventType.
    static var idleSeconds: TimeInterval {
        let types: [CGEventType] = [
            .keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown,
            .otherMouseDown, .mouseMoved, .scrollWheel,
        ]
        return types.map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }.min() ?? .infinity
    }
}
