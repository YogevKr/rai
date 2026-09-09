import Foundation
import XCTest
@testable import RaiCore

final class MachineNotificationTests: XCTestCase {
    private func entry(_ profile: String = "a", connection: String = "connection") -> MachineEntry {
        .init(endpoint: .init(profileID: String(repeating: profile, count: 32), session: "default"),
              label: "Duplicate", connectionID: connection, health: .online)
    }

    private func snapshot(_ status: String?, boot: String = "boot") throws -> HerdrEndpointSnapshot {
        let agents: [[String: Any]] = status.map { [["pane_id": "w1:p1", "name": "Build", "agent_status": $0]] } ?? []
        return try JSONDecoder().decode(HerdrEndpointSnapshot.self, from: JSONSerialization.data(withJSONObject:
            ["boot_id": boot, "revision": 1, "agents": agents]))
    }

    func testSeparateMachinesEmitSeparateNoticesWithoutInitialOrReconnectReplay() throws {
        var tracker = MachineNotificationTracker()
        let one = entry(), two = entry("b")
        XCTAssertTrue(tracker.receive(try snapshot("working"), entry: one).notices.isEmpty)
        XCTAssertTrue(tracker.receive(try snapshot("working"), entry: two).notices.isEmpty)
        let first = tracker.receive(try snapshot("blocked"), entry: one)
        let second = tracker.receive(try snapshot("blocked"), entry: two)
        XCTAssertEqual(first.notices.count, 1)
        XCTAssertEqual(second.notices.count, 1)
        XCTAssertNotEqual(first.notices.first?.id, second.notices.first?.id)
        XCTAssertTrue(tracker.receive(try snapshot("blocked"), entry: one).notices.isEmpty)
        tracker.disconnect(one.endpoint)
        XCTAssertTrue(tracker.receive(try snapshot("blocked"), entry: entry(connection: "next")).notices.isEmpty)
        XCTAssertTrue(tracker.receive(try snapshot("done", boot: "new-boot"), entry: one).notices.isEmpty)
    }

    func testCompletionAndRemovalRetractExactMachineNotice() throws {
        var tracker = MachineNotificationTracker()
        let entry = entry()
        _ = tracker.receive(try snapshot("working"), entry: entry)
        let done = tracker.receive(try snapshot("idle"), entry: entry)
        XCTAssertEqual(done.notices.first?.status, .done)
        let removed = tracker.receive(try snapshot(nil), entry: entry)
        XCTAssertEqual(removed.retiredIDs, done.notices.map(\.id))
        XCTAssertTrue(removed.notices.isEmpty)
    }

    func testMalformedMachinePayloadNeverUsesLegacyPaneRouting() throws {
        XCTAssertEqual(MachineNotificationRoute.decode(["paneID": "w1:p1"]), .legacy)
        for malformed: Any in ["bad", ["paneID": "w1:p1"], NSNull()] {
            XCTAssertEqual(MachineNotificationRoute.decode(["machineResource": malformed, "paneID": "w1:p1"]), .invalid)
        }
        let target = MachineResource(endpoint: entry().endpoint, connectionID: "old", bootID: "boot", paneID: "w1:p1")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(target))
        XCTAssertEqual(MachineNotificationRoute.decode(["machineResource": encoded, "paneID": "other", "request_id": "forged"]), .machine(target))
        let fresh = MachineResource(endpoint: target.endpoint, connectionID: "new", bootID: target.bootID, paneID: target.paneID)
        XCTAssertEqual(target.notificationID, fresh.notificationID)
    }

    func testCombinedSearchKeepsDuplicateAndDisconnectedAgentIdentities() {
        let one = entry(), two = entry("b")
        let first = MachineAgent(resource: .init(endpoint: one.endpoint, connectionID: "one", bootID: "boot", paneID: "w1:p1"), name: "Build", agent: "codex", status: "blocked")
        let second = MachineAgent(resource: .init(endpoint: two.endpoint, connectionID: "two", bootID: "boot", paneID: "w1:p1"), name: "Build", agent: "codex", status: "working")
        let rows = [MachineEntry(endpoint: one.endpoint, label: "Duplicate", health: .online, agents: [first], target: "one"),
                    MachineEntry(endpoint: two.endpoint, label: "Duplicate", health: .disconnected, agents: [second], target: "two")]
        XCTAssertEqual(rows.flatMap { $0.matchingAgents(query: "BUILD", status: "All") }.count, 2)
        XCTAssertEqual(rows.flatMap { $0.matchingAgents(query: "duplicate", status: "blocked") }, [first])
        XCTAssertEqual(rows.flatMap { $0.matchingAgents(query: "two", status: "All") }, [second])
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(rows[0].addressLabel, rows[1].addressLabel)
    }
    func testNewBlockedAgentNotifiesAfterTheInitialSnapshot() throws {
        var tracker = MachineNotificationTracker()
        let entry = entry()
        XCTAssertTrue(tracker.receive(try snapshot(nil), entry: entry).notices.isEmpty)
        XCTAssertEqual(tracker.receive(try snapshot("blocked"), entry: entry).notices.count, 1)
        XCTAssertTrue(tracker.receive(try snapshot("blocked"), entry: entry).notices.isEmpty)
    }

}
