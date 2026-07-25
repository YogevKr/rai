import CorralCore
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

    func testAgentStartSplitsWithoutChangingFocus() {
        XCTAssertEqual(
            PaneActionPlanner.agentStartArguments(
                name: "claude-a1b2c3",
                executable: "claude",
                direction: .down,
                cwd: "/tmp/project with spaces"
            ),
            [
                "agent", "start", "claude-a1b2c3",
                "--split", "down",
                "--cwd", "/tmp/project with spaces",
                "--no-focus",
                "--", "claude",
            ]
        )
    }
}
