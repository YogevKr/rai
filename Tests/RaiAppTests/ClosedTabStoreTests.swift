import XCTest
@testable import RaiApp
@testable import RaiCore

final class ClosedTabStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "rai-closed-tab-store-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try super.tearDownWithError()
    }

    private var store: ClosedTabStore { ClosedTabStore(userDefaults: defaults) }

    func testRoundTripsARecordWithItsFullShape() {
        let record = ClosedTabRecord(
            workspaceID: "w1",
            cwd: "/repo",
            agentKind: .claude,
            agentSession: nil,
            label: "Agent",
            agentArgv: ["claude", "--resume", "abc"],
            shape: ClosedTabShape(
                seeds: [
                    ClosedPaneSeed(
                        cwd: "/repo",
                        agentKind: .claude,
                        agentSession: nil,
                        agentArgv: ["claude", "--resume", "abc"]
                    ),
                    ClosedPaneSeed(cwd: "/repo/sub", agentKind: nil, agentSession: nil),
                ],
                steps: [
                    TabRebuildStep(anchorLeaf: 0, newLeaf: 1, direction: .right, ratio: 0.6)
                ],
                focusedLeaf: 1,
                zoomed: false
            )
        )

        store.save([record], herdKey: "default")
        let loaded = store.load(herdKey: "default")

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.label, "Agent")
        XCTAssertEqual(loaded.first?.agentArgv, ["claude", "--resume", "abc"])
        XCTAssertEqual(loaded.first?.shape, record.shape)
    }

    func testHerdsKeepSeparateStacks() {
        let record = ClosedTabRecord(
            workspaceID: "w1", cwd: "/a", agentKind: nil,
            agentSession: nil, label: "Shell"
        )
        store.save([record], herdKey: "default")

        XCTAssertTrue(store.load(herdKey: "workbox#default").isEmpty)
        XCTAssertEqual(store.load(herdKey: "default").count, 1)
    }

    func testRemoteHerdKeyIncludesTheTarget() {
        XCTAssertEqual(
            ClosedTabStore.herdKey(sessionName: "default", remoteTarget: nil),
            "default"
        )
        XCTAssertEqual(
            ClosedTabStore.herdKey(sessionName: "default", remoteTarget: "workbox"),
            "workbox#default"
        )
    }

    func testCapsAtTenNewestRecords() {
        let records = (0..<14).map { index in
            ClosedTabRecord(
                workspaceID: "w1", cwd: "/a", agentKind: nil,
                agentSession: nil, label: "tab-\(index)"
            )
        }
        store.save(records, herdKey: "default")
        let loaded = store.load(herdKey: "default")
        XCTAssertEqual(loaded.count, ClosedTabStore.maxRecords)
        // The stack pops from the end, so the newest records must survive.
        XCTAssertEqual(loaded.last?.label, "tab-13")
        XCTAssertEqual(loaded.first?.label, "tab-4")
    }

    func testEmptySaveClearsAndCorruptDataLoadsEmpty() {
        let record = ClosedTabRecord(
            workspaceID: "w1", cwd: "/a", agentKind: nil,
            agentSession: nil, label: "Shell"
        )
        store.save([record], herdKey: "default")
        store.save([], herdKey: "default")
        XCTAssertTrue(store.load(herdKey: "default").isEmpty)

        defaults.set(Data("not json".utf8), forKey: "closedTabs.v1.broken")
        XCTAssertTrue(store.load(herdKey: "broken").isEmpty)
    }
}
