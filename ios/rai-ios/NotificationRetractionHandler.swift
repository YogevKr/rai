import RaiCore
import UserNotifications

struct DeliveredNotificationRecord: Equatable, Sendable {
    let requestIdentifier: String
    let stableIdentifiers: Set<String>
    let notificationTimestamp: TimeInterval?
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

    init(center: PhoneNotificationCenter) {
        self.center = center
    }

    func handle(userInfo: [AnyHashable: Any]) async -> Bool {
        guard let raw = userInfo["retractNotificationIDs"] as? [String],
              !raw.isEmpty else { return false }
        let retracted = Set(raw)
        let cutoff = (userInfo["retractedBefore"] as? NSNumber)?.doubleValue
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
        await center.setBadgeCount(delivered.count - matches.count)
        return true
    }
}
