import RaiCore
import XCTest

final class PaneActionPlannerTests: XCTestCase {
    func testSameTabDropSwapsPanes() {
        XCTAssertEqual(
            PaneActionPlanner.dropArguments(
                sourcePaneID: "w1:p1",
                sourceTabID: "w1:t1",
                targetPaneID: "w1:p2",
                targetTabID: "w1:t1",
                moveDirection: .down
            ),
            [
                "pane", "swap",
                "--source-pane", "w1:p1",
                "--target-pane", "w1:p2",
            ]
        )
    }

    func testCrossTabDropMovesBesideTargetWithoutFocus() {
        XCTAssertEqual(
            PaneActionPlanner.dropArguments(
                sourcePaneID: "w1:p1",
                sourceTabID: "w1:t1",
                targetPaneID: "w1:p3",
                targetTabID: "w1:t2",
                moveDirection: .right
            ),
            [
                "pane", "move", "w1:p1",
                "--tab", "w1:t2",
                "--split", "right",
                "--target-pane", "w1:p3",
                "--no-focus",
            ]
        )
    }

    func testDroppingOntoSelfDoesNothing() {
        XCTAssertNil(
            PaneActionPlanner.dropArguments(
                sourcePaneID: "w1:p1",
                sourceTabID: "w1:t1",
                targetPaneID: "w1:p1",
                targetTabID: "w1:t1",
                moveDirection: .right
            )
        )
    }

    /// herdr ≥0.7.5 removed `agent start --split/--workspace/--tab`; an
    /// agent's host pane is built explicitly, then the launch is started
    /// against it (`agentStartArguments` for a fresh launch, `pane run` for a
    /// resume that needs shell `||` fallback logic). (Regression: the old
    /// argv failed with "unknown option" on 0.7.5+ and agent launches
    /// silently did nothing.)
    func testAgentSplitBuildsHostPaneWithoutChangingFocus() {
        XCTAssertEqual(
            PaneActionPlanner.agentSplitArguments(
                paneID: "w1:p1",
                direction: .down,
                cwd: "/tmp/project with spaces"
            ),
            [
                "pane", "split", "w1:p1",
                "--direction", "down",
                "--cwd", "/tmp/project with spaces",
                "--no-focus",
            ]
        )
    }

    func testRemoteAgentTabTargetsWorkspaceWithoutChangingFocus() {
        XCTAssertEqual(
            PaneActionPlanner.agentTabCreateArguments(
                workspaceID: "workspace-1",
                cwd: "/tmp/project with spaces"
            ),
            [
                "tab", "create",
                "--workspace", "workspace-1",
                "--cwd", "/tmp/project with spaces",
                "--no-focus",
            ]
        )
    }

    func testRemoteAgentTabOmitsMissingCwd() {
        XCTAssertEqual(
            PaneActionPlanner.agentTabCreateArguments(
                workspaceID: "workspace-1",
                cwd: nil
            ),
            [
                "tab", "create",
                "--workspace", "workspace-1",
                "--no-focus",
            ]
        )
    }

    /// A fresh, no-resume launch waits on herdr's own readiness check
    /// instead of a guessed delay (verified in the isolated herdr lab: 5/5
    /// at 0ms). Only valid without a resume fallback — herdr execs the
    /// kind's canonical binary with these trailing args directly, so it
    /// can't carry a `first || fallback` shell chain.
    func testAgentStartTargetsAnExistingPane() {
        XCTAssertEqual(
            PaneActionPlanner.agentStartArguments(
                name: "claude-a1b2c3",
                kind: "claude",
                paneID: "w1:p2"
            ),
            [
                "agent", "start", "claude-a1b2c3",
                "--kind", "claude",
                "--pane", "w1:p2",
            ]
        )
    }
}
