import XCTest

@testable import rai

final class NotificationRetractionHandlerTests: XCTestCase {
    func testRemovesMatchingSingleAndBurstNotificationsThenRecomputesBadge() async {
        let center = FakePhoneNotificationCenter(delivered: [
            .init(
                requestIdentifier: "system-1",
                stableIdentifiers: ["agent-p1"],
                notificationTimestamp: 100
            ),
            .init(
                requestIdentifier: "system-burst",
                stableIdentifiers: ["agent-p2", "agent-p3"],
                notificationTimestamp: 100
            ),
            .init(
                requestIdentifier: "system-4",
                stableIdentifiers: ["agent-p4"],
                notificationTimestamp: 100
            ),
        ])
        let handler = PhoneNotificationRetractionHandler(center: center)

        let handled = await handler.handle(userInfo: [
            "retractNotificationIDs": ["agent-p1", "agent-p3"],
            "retractedBefore": 200.0,
        ])

        XCTAssertTrue(handled)
        XCTAssertEqual(Set(center.removedIdentifiers), ["system-1", "system-burst"])
        XCTAssertEqual(center.badgeCount, 1)
    }

    func testKeepsAReplacementNotificationNewerThanRetraction() async {
        let center = FakePhoneNotificationCenter(delivered: [
            .init(
                requestIdentifier: "system-new",
                stableIdentifiers: ["agent-p1"],
                notificationTimestamp: 300
            ),
        ])
        let handler = PhoneNotificationRetractionHandler(center: center)

        let handled = await handler.handle(userInfo: [
            "retractNotificationIDs": ["agent-p1"],
            "retractedBefore": 200.0,
        ])

        XCTAssertTrue(handled)
        XCTAssertTrue(center.removedIdentifiers.isEmpty)
        XCTAssertEqual(center.badgeCount, 1)
    }

    func testIgnoresNormalPushPayload() async {
        let center = FakePhoneNotificationCenter(delivered: [])
        let handler = PhoneNotificationRetractionHandler(center: center)

        let handled = await handler.handle(userInfo: ["paneID": "p1"])

        XCTAssertFalse(handled)
        XCTAssertTrue(center.removedIdentifiers.isEmpty)
        XCTAssertNil(center.badgeCount)
    }

    func testSerializesConcurrentRetractionsBeforeSettingBadge() async {
        let center = FakePhoneNotificationCenter(delivered: [
            .init(
                requestIdentifier: "system-1",
                stableIdentifiers: ["agent-p1"],
                notificationTimestamp: 100
            ),
            .init(
                requestIdentifier: "system-2",
                stableIdentifiers: ["agent-p2"],
                notificationTimestamp: 100
            ),
        ])
        let handler = PhoneNotificationRetractionHandler(center: center)

        async let first = handler.handle(userInfo: [
            "retractNotificationIDs": ["agent-p1"],
            "retractedBefore": 200.0,
        ])
        async let second = handler.handle(userInfo: [
            "retractNotificationIDs": ["agent-p2"],
            "retractedBefore": 200.0,
        ])
        _ = await (first, second)

        XCTAssertEqual(Set(center.removedIdentifiers), ["system-1", "system-2"])
        XCTAssertEqual(center.badgeCount, 0)
    }

    func testRetractionDoesNotRestoreBadgeForAlertsSeenAtActivation() async {
        let center = FakePhoneNotificationCenter(delivered: [
            .init(
                requestIdentifier: "system-seen",
                stableIdentifiers: ["agent-seen"],
                notificationTimestamp: 100
            ),
            .init(
                requestIdentifier: "system-retracted",
                stableIdentifiers: ["agent-retracted"],
                notificationTimestamp: 100
            ),
        ])
        let store = FakePhoneNotificationReadStateStore()
        let handler = PhoneNotificationRetractionHandler(
            center: center,
            readStateStore: store
        )
        await handler.markDeliveredNotificationsSeen()

        let handled = await handler.handle(userInfo: [
            "retractNotificationIDs": ["agent-retracted"],
            "retractedBefore": 200.0,
        ])

        XCTAssertTrue(handled)
        XCTAssertEqual(center.badgeCount, 0)
        XCTAssertEqual(store.seenRequestIdentifiers, ["system-seen"])
    }

    func testRetractionCountsOnlyAlertsDeliveredAfterActivation() async {
        let center = FakePhoneNotificationCenter(delivered: [
            .init(
                requestIdentifier: "system-seen",
                stableIdentifiers: ["agent-seen"],
                notificationTimestamp: 100
            ),
        ])
        let handler = PhoneNotificationRetractionHandler(center: center)
        await handler.markDeliveredNotificationsSeen()
        center.deliver(.init(
            requestIdentifier: "system-unread",
            stableIdentifiers: ["agent-unread"],
            notificationTimestamp: 200
        ))

        _ = await handler.handle(userInfo: [
            "retractNotificationIDs": ["missing"],
            "retractedBefore": 300.0,
        ])

        XCTAssertEqual(center.badgeCount, 1)
    }
}

private final class FakePhoneNotificationReadStateStore: PhoneNotificationReadStateStore {
    private(set) var seenRequestIdentifiers: Set<String> = []

    func loadSeenRequestIdentifiers() -> Set<String> { seenRequestIdentifiers }

    func saveSeenRequestIdentifiers(_ identifiers: Set<String>) {
        seenRequestIdentifiers = identifiers
    }
}

private final class FakePhoneNotificationCenter: PhoneNotificationCenter {
    private var delivered: [DeliveredNotificationRecord]
    private(set) var removedIdentifiers: [String] = []
    private(set) var badgeCount: Int?

    init(delivered: [DeliveredNotificationRecord]) {
        self.delivered = delivered
    }

    func deliveredNotifications() async -> [DeliveredNotificationRecord] {
        delivered
    }

    func deliver(_ notification: DeliveredNotificationRecord) {
        delivered.append(notification)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        removedIdentifiers.append(contentsOf: identifiers)
        let removed = Set(identifiers)
        delivered.removeAll { removed.contains($0.requestIdentifier) }
    }

    func setBadgeCount(_ count: Int) async {
        badgeCount = count
    }
}
