import XCTest
@testable import RaiApp

final class ClosedPaneStoreTests: XCTestCase {
    @MainActor
    func testLiveProcessCaptureReplacesStaleWorkingDirectory() {
        var record = ClosedPaneRecord(
            workspaceID: "w1", tabID: "t1", cwd: "/old",
            agentKind: nil, agentSession: nil, label: "shell"
        )
        record.captureProcessInfo(PaneProcessInfo(
            paneID: "p1", shellPID: 42, tty: nil, foregroundProcessGroupID: 42,
            foregroundProcesses: [.init(
                pid: 42, name: "zsh", argv0: "zsh", argv: ["zsh"],
                cmdline: "zsh", cwd: "/new"
            )]
        ))
        XCTAssertEqual(record.cwd, "/new")
        XCTAssertNil(record.agentArgv)
    }

    func testRoundTripsPaneRecordPerHerd() throws {
        let suite = "rai-closed-pane-store-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ClosedPaneStore(userDefaults: defaults)
        let record = ClosedPaneRecord(
            workspaceID: "w1",
            tabID: "t1",
            cwd: "/repo",
            agentKind: .claude,
            agentSession: nil,
            label: "shell",
            agentArgv: ["claude", "--continue"]
        )

        store.save([record], herdKey: "default")

        let loaded = store.load(herdKey: "default")
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.tabID, "t1")
        XCTAssertEqual(loaded.first?.agentArgv, ["claude", "--continue"])
        XCTAssertTrue(store.load(herdKey: "other").isEmpty)
    }
}
