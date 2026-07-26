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

    // MARK: reorderEligible — dropUpdated/performDrop's decision

    func testTabReorderEligibleWithinSameWorkspace() {
        XCTAssertTrue(
            SidebarDropRules.reorderEligible(
                draggedID: "w1:t4",
                targetID: "w1:t2",
                hasReorderType: true,
                sourceWorkspaceID: "w1",
                targetWorkspaceID: "w1"
            )
        )
    }

    func testSelfDropIsNotEligible() {
        XCTAssertFalse(
            SidebarDropRules.reorderEligible(
                draggedID: "w1:t4",
                targetID: "w1:t4",
                hasReorderType: true,
                sourceWorkspaceID: "w1",
                targetWorkspaceID: "w1"
            )
        )
    }

    func testCrossWorkspaceTabDropIsNotEligible() {
        XCTAssertFalse(
            SidebarDropRules.reorderEligible(
                draggedID: "w1:t4",
                targetID: "w2:t1",
                hasReorderType: true,
                sourceWorkspaceID: "w1",
                targetWorkspaceID: "w2"
            )
        )
    }

    func testMissingDraggedIDIsNotEligible() {
        XCTAssertFalse(
            SidebarDropRules.reorderEligible(
                draggedID: nil,
                targetID: "w1:t2",
                hasReorderType: true,
                sourceWorkspaceID: "w1",
                targetWorkspaceID: "w1"
            )
        )
    }

    func testWrongPayloadTypeIsNotEligible() {
        XCTAssertFalse(
            SidebarDropRules.reorderEligible(
                draggedID: "w1:t4",
                targetID: "w1:t2",
                hasReorderType: false,
                sourceWorkspaceID: "w1",
                targetWorkspaceID: "w1"
            )
        )
    }

    func testWorkspaceReorderEligibleWithoutWorkspaceConstraint() {
        XCTAssertTrue(
            SidebarDropRules.reorderEligible(
                draggedID: "w1",
                targetID: "w2",
                hasReorderType: true,
                sourceWorkspaceID: nil,
                targetWorkspaceID: nil
            )
        )
    }
}
