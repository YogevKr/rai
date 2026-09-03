import RaiCore
import UserNotifications

struct DeliveredNotificationRecord: Equatable, Sendable {
    let requestIdentifier: String
    let stableIdentifiers: Set<String>
    let notificationTimestamp: TimeInterval?
}

protocol PhoneNotificationReadStateStore: AnyObject {
    func loadSeenRequestIdentifiers() -> Set<String>
    func saveSeenRequestIdentifiers(_ identifiers: Set<String>)
}

final class UserDefaultsPhoneNotificationReadStateStore: PhoneNotificationReadStateStore {
    private static let key = "seenPushNotificationRequestIdentifiers"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadSeenRequestIdentifiers() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    func saveSeenRequestIdentifiers(_ identifiers: Set<String>) {
        defaults.set(identifiers.sorted(), forKey: Self.key)
    }
}

private final class MemoryPhoneNotificationReadStateStore: PhoneNotificationReadStateStore {
    private var identifiers: Set<String> = []

    func loadSeenRequestIdentifiers() -> Set<String> { identifiers }

    func saveSeenRequestIdentifiers(_ identifiers: Set<String>) {
        self.identifiers = identifiers
    }
}

protocol PhoneNotificationCenter: AnyObject {
    func deliveredNotifications() async -> [DeliveredNotificationRecord]
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
    func setBadgeCount(_ count: Int) async
}

final class SystemPhoneNotificationCenter: PhoneNotificationCenter {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func deliveredNotifications() async -> [DeliveredNotificationRecord] {
        let notifications = await withCheckedContinuation { continuation in
            center.getDeliveredNotifications { continuation.resume(returning: $0) }
        }
        return notifications.map { notification in
            let info = notification.request.content.userInfo
            var identifiers = Set(info["notificationIDs"] as? [String] ?? [])
            if let identifier = info["notificationID"] as? String {
                identifiers.insert(identifier)
            }
            if identifiers.isEmpty, let paneID = info["paneID"] as? String {
                identifiers.insert(PushNotificationIdentity.pane(paneID))
            }
            return DeliveredNotificationRecord(
                requestIdentifier: notification.request.identifier,
                stableIdentifiers: identifiers,
                notificationTimestamp: (info["notificationTimestamp"] as? NSNumber)?.doubleValue
            )
        }
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func setBadgeCount(_ count: Int) async {
        try? await center.setBadgeCount(count)
    }
}

actor PhoneNotificationRetractionHandler {
    let center: PhoneNotificationCenter
    private let readStateStore: PhoneNotificationReadStateStore
    private var seenRequestIdentifiers: Set<String>
    private var operationTail: Task<Void, Never>?

    init(center: PhoneNotificationCenter) {
        let readStateStore = MemoryPhoneNotificationReadStateStore()
        self.center = center
        self.readStateStore = readStateStore
        seenRequestIdentifiers = readStateStore.loadSeenRequestIdentifiers()
    }

    init(
        center: PhoneNotificationCenter,
        readStateStore: PhoneNotificationReadStateStore
    ) {
        self.center = center
        self.readStateStore = readStateStore
        seenRequestIdentifiers = readStateStore.loadSeenRequestIdentifiers()
    }

    func markDeliveredNotificationsSeen() async {
        let previousOperation = operationTail
        let operation = Task { [weak self] in
            await previousOperation?.value
            await self?.performMarkDeliveredNotificationsSeen()
        }
        operationTail = operation
        await operation.value
    }

    private func performMarkDeliveredNotificationsSeen() async {
        let delivered = await center.deliveredNotifications()
        seenRequestIdentifiers = Set(delivered.map(\.requestIdentifier))
        readStateStore.saveSeenRequestIdentifiers(seenRequestIdentifiers)
        await center.setBadgeCount(0)
    }

    func handle(userInfo: [AnyHashable: Any]) async -> Bool {
        guard let raw = userInfo["retractNotificationIDs"] as? [String],
              !raw.isEmpty else { return false }
        let retracted = Set(raw)
        let cutoff = (userInfo["retractedBefore"] as? NSNumber)?.doubleValue
        let previousOperation = operationTail
        let operation = Task { [weak self] in
            await previousOperation?.value
            await self?.performRetraction(retracted: retracted, cutoff: cutoff)
        }
        operationTail = operation
        await operation.value
        return true
    }

    private func performRetraction(
        retracted: Set<String>,
        cutoff: TimeInterval?
    ) async {
        let delivered = await center.deliveredNotifications()
        let matches = delivered.filter {
            let identifiersMatch = retracted.contains($0.requestIdentifier)
                || !$0.stableIdentifiers.isDisjoint(with: retracted)
            guard identifiersMatch else { return false }
            guard let cutoff, let notificationTimestamp = $0.notificationTimestamp else {
                return true
            }
            return notificationTimestamp <= cutoff
        }
        // A coalesced notification is one atomic delivered request. If one
        // represented pane changes, remove the stale summary. Triage remains
        // authoritative for other panes in that summary.
        center.removeDeliveredNotifications(
            withIdentifiers: matches.map(\.requestIdentifier)
        )
        let matchedRequestIdentifiers = Set(matches.map(\.requestIdentifier))
        let remainingRequestIdentifiers = Set(delivered.map(\.requestIdentifier))
            .subtracting(matchedRequestIdentifiers)
        seenRequestIdentifiers.formIntersection(remainingRequestIdentifiers)
        readStateStore.saveSeenRequestIdentifiers(seenRequestIdentifiers)
        await center.setBadgeCount(
            remainingRequestIdentifiers.subtracting(seenRequestIdentifiers).count
        )
    }
}
