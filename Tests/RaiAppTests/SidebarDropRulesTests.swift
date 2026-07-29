@testable import RaiApp
import XCTest

final class SidebarDropRulesTests: XCTestCase {
    // MARK: acceptsSession — validateDrop's decision

    // The regression that broke drag-to-reorder: a reorder drag always starts
    // over its own row, and rejecting that first validateDrop ends delegate
    // callbacks for the whole session. The session must be accepted on payload
    // type alone — even when the row under the cursor is the dragged row.
    func testReorderSessionAcceptedOverSourceRow() {
        XCTAssertTrue(
            SidebarDropRules.acceptsSession(
                paneDrag: false,
                hasReorderType: true,
                supportsPaneHover: true
            )
        )
        XCTAssertTrue(
            SidebarDropRules.acceptsSession(
                paneDrag: false,
                hasReorderType: true,
                supportsPaneHover: false
            )
        )
    }

    func testForeignSessionRejected() {
        XCTAssertFalse(
            SidebarDropRules.acceptsSession(
                paneDrag: false,
                hasReorderType: false,
                supportsPaneHover: true
            )
        )
    }

    func testPaneSessionAcceptedOnlyWithHoverSupport() {
        XCTAssertTrue(
            SidebarDropRules.acceptsSession(
                paneDrag: true,
                hasReorderType: false,
                supportsPaneHover: true
            )
        )
        XCTAssertFalse(
            SidebarDropRules.acceptsSession(
                paneDrag: true,
                hasReorderType: false,
                supportsPaneHover: false
            )
        )
    }

    // MARK: tabRowAction — dropUpdated/performDrop's decision on tab rows

    func testTabDropWithinSameWorkspaceReorders() {
        XCTAssertEqual(
            SidebarDropRules.tabRowAction(
                draggedTabID: "w1:t4",
                targetTabID: "w1:t2",
                hasTabType: true,
                sourceWorkspaceID: "w1",
                targetWorkspaceID: "w1"
            ),
            .reorder
        )
    }

    func testSelfDropIsNotEligible() {
        XCTAssertNil(
            SidebarDropRules.tabRowAction(
                draggedTabID: "w1:t4",
                targetTabID: "w1:t4",
                hasTabType: true,
                sourceWorkspaceID: "w1",
                targetWorkspaceID: "w1"
            )
        )
    }

    func testCrossWorkspaceTabDropMovesInFrontOfTargetRow() {
        XCTAssertEqual(
            SidebarDropRules.tabRowAction(
                draggedTabID: "w1:t4",
                targetTabID: "w2:t1",
                hasTabType: true,
                sourceWorkspaceID: "w1",
                targetWorkspaceID: "w2"
            ),
            .moveTabToWorkspace(workspaceID: "w2", insertBeforeTabID: "w2:t1")
        )
    }

    func testMissingDraggedIDIsNotEligible() {
        XCTAssertNil(
            SidebarDropRules.tabRowAction(
                draggedTabID: nil,
                targetTabID: "w1:t2",
                hasTabType: true,
                sourceWorkspaceID: "w1",
                targetWorkspaceID: "w1"
            )
        )
    }

    func testWrongPayloadTypeIsNotEligible() {
        XCTAssertNil(
            SidebarDropRules.tabRowAction(
                draggedTabID: "w1:t4",
                targetTabID: "w1:t2",
                hasTabType: false,
                sourceWorkspaceID: "w1",
                targetWorkspaceID: "w1"
            )
        )
    }

    // A dragged tab whose workspace can't be resolved from the snapshot must
    // not move anywhere.
    func testUnknownWorkspaceIsNotEligible() {
        XCTAssertNil(
            SidebarDropRules.tabRowAction(
                draggedTabID: "w1:t4",
                targetTabID: "w2:t1",
                hasTabType: true,
                sourceWorkspaceID: nil,
                targetWorkspaceID: "w2"
            )
        )
    }

    // MARK: headerAction — drops landing on a workspace header

    func testWorkspacePayloadOnHeaderReorders() {
        XCTAssertEqual(
            SidebarDropRules.headerAction(
                draggedWorkspaceID: "w1",
                draggedTabID: nil,
                tabWorkspaceID: nil,
                targetWorkspaceID: "w2",
                hasWorkspaceType: true,
                hasTabType: false
            ),
            .reorder
        )
    }

    func testWorkspaceSelfDropOnHeaderIsNotEligible() {
        XCTAssertNil(
            SidebarDropRules.headerAction(
                draggedWorkspaceID: "w1",
                draggedTabID: nil,
                tabWorkspaceID: nil,
                targetWorkspaceID: "w1",
                hasWorkspaceType: true,
                hasTabType: false
            )
        )
    }

    func testTabPayloadOnForeignHeaderAppendsToThatSpace() {
        XCTAssertEqual(
            SidebarDropRules.headerAction(
                draggedWorkspaceID: nil,
                draggedTabID: "w1:t4",
                tabWorkspaceID: "w1",
                targetWorkspaceID: "w2",
                hasWorkspaceType: false,
                hasTabType: true
            ),
            .moveTabToWorkspace(workspaceID: "w2", insertBeforeTabID: nil)
        )
    }

    func testTabPayloadOnOwnHeaderIsNotEligible() {
        XCTAssertNil(
            SidebarDropRules.headerAction(
                draggedWorkspaceID: nil,
                draggedTabID: "w1:t4",
                tabWorkspaceID: "w1",
                targetWorkspaceID: "w1",
                hasWorkspaceType: false,
                hasTabType: true
            )
        )
    }
}
