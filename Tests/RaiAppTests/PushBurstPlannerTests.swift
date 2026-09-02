import RaiCore
import XCTest

@testable import RaiApp

final class PushBurstPlannerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testEventsInsideWindowBecomeOneSummaryPush() {
        let pushes = PushBurstPlanner.plan(
            events: [
                event("p1", "Build", seconds: 0),
                event("p2", "Tests", seconds: 4),
                event("p3", "Review", seconds: 10),
            ],
            window: 15
        )

        XCTAssertEqual(pushes.count, 1)
        XCTAssertEqual(pushes[0].title, "3 agents need you")
        XCTAssertEqual(pushes[0].body, "Build, Tests, Review")
        XCTAssertNil(pushes[0].paneID)
        XCTAssertFalse(pushes[0].requiresAttention)
    }

    func testGapAfterWindowStartsAnotherPush() {
        let pushes = PushBurstPlanner.plan(
            events: [
                event("p1", "Build", seconds: 0),
                event("p2", "Tests", seconds: 5),
                event("p3", "Review", seconds: 21),
            ],
            window: 15
        )

        XCTAssertEqual(pushes.map(\.events.count), [2, 1])
        XCTAssertEqual(pushes[1].paneID, "p3")
        XCTAssertEqual(pushes[1].title, "Review")
    }

    func testSingleBlockedEventKeepsPaneActionAndLink() {
        let push = PushBurstPlanner.plan(
            events: [event("p1", "Build", status: .blocked, seconds: 0)],
            window: 15
        )[0]

        XCTAssertEqual(push.paneID, "p1")
        XCTAssertEqual(push.body, "Needs you")
        XCTAssertTrue(push.requiresAttention)
        XCTAssertEqual(push.notificationIDs, ["agent-p1"])
    }

    func testSingleDoneEventHasNoAttentionActions() {
        let push = PushBurstPlanner.plan(
            events: [event("p1", "Build", status: .done, seconds: 0)],
            window: 15
        )[0]

        XCTAssertEqual(push.body, "Finished")
        XCTAssertFalse(push.requiresAttention)
    }

    func testDoneEventsUseTheRequiredTriageSummaryTitle() {
        let push = PushBurstPlanner.plan(
            events: [
                event("p1", "Build", status: .done, seconds: 0),
                event("p2", "Tests", status: .done, seconds: 1),
            ],
            window: 15
        )[0]

        XCTAssertEqual(push.title, "2 agents need you")
        XCTAssertNil(push.paneID)
        XCTAssertFalse(push.requiresAttention)
    }

    func testLargeWindowSplitsAtTheAPNsIdentifierLimit() {
        let events = (0..<70).map {
            event("p\($0)", "Agent \($0)", seconds: TimeInterval($0) / 10)
        }
        let pushes = PushBurstPlanner.plan(events: events, window: 15)

        XCTAssertEqual(pushes.map(\.events.count), [32, 32, 6])
        XCTAssertEqual(pushes.flatMap(\.events), events)
    }

    func testLongPaneIdentifierUsesABoundedStableFallback() {
        let paneID = String(repeating: "pane-", count: 100)
        let first = PushNotificationIdentity.pane(paneID)

        XCTAssertEqual(first, PushNotificationIdentity.pane(paneID))
        XCTAssertTrue(first.hasPrefix("agent-hash-"))
        XCTAssertLessThan(first.utf8.count, 64)
    }

    func testNotifiedPaneStoreSurvivesProcessStateRecreation() {
        let suite = "rai-push-store-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        NotifiedPaneStore.save(["p1": .blocked, "p2": .done], defaults: defaults)

        XCTAssertEqual(
            NotifiedPaneStore.load(defaults: defaults),
            ["p1": .blocked, "p2": .done]
        )
        NotifiedPaneStore.save([:], defaults: defaults)
        XCTAssertEqual(NotifiedPaneStore.load(defaults: defaults), [:])
    }

    func testUntrackedSelectedPaneDoesNotCauseRetraction() {
        let paneIDs = NotificationRetractionPlanner.paneIDs(
            notifiedStatuses: ["tracked": .blocked],
            currentStatuses: ["tracked": .blocked, "selected": .working],
            selectedPaneID: "selected"
        )

        XCTAssertTrue(paneIDs.isEmpty)
    }

    func testTrackedSelectedPaneCausesRetraction() {
        let paneIDs = NotificationRetractionPlanner.paneIDs(
            notifiedStatuses: ["selected": .blocked],
            currentStatuses: ["selected": .blocked],
            selectedPaneID: "selected"
        )

        XCTAssertEqual(paneIDs, ["selected"])
    }

    private func event(
        _ paneID: String,
        _ name: String,
        status: AgentStatus = .blocked,
        seconds: TimeInterval
    ) -> PhonePushEvent {
        PhonePushEvent(
            paneID: paneID,
            paneName: name,
            workspaceID: "workspace-1",
            workspaceName: "rai",
            status: status,
            occurredAt: start.addingTimeInterval(seconds)
        )
    }
}
