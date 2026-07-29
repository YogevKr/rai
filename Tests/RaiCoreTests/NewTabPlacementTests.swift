import XCTest
@testable import RaiCore

final class NewTabPlacementTests: XCTestCase {
    func testInsertsAfterAnchorInMiddleOfStrip() {
        XCTAssertEqual(
            NewTabPlacement.insertIndex(
                tabs: [tab("t1"), tab("t2"), tab("t3")],
                workspaceID: "w1",
                afterTabID: "t1"
            ),
            1
        )
        XCTAssertEqual(
            NewTabPlacement.insertIndex(
                tabs: [tab("t1"), tab("t2"), tab("t3")],
                workspaceID: "w1",
                afterTabID: "t2"
            ),
            2
        )
    }

    func testLastAnchorNeedsNoReorder() {
        XCTAssertNil(
            NewTabPlacement.insertIndex(
                tabs: [tab("t1"), tab("t2")],
                workspaceID: "w1",
                afterTabID: "t2"
            )
        )
    }

    func testNoAnchorAppends() {
        XCTAssertNil(
            NewTabPlacement.insertIndex(
                tabs: [tab("t1"), tab("t2")],
                workspaceID: "w1",
                afterTabID: nil
            )
        )
    }

    func testAnchorOutsideTargetWorkspaceAppends() {
        XCTAssertNil(
            NewTabPlacement.insertIndex(
                tabs: [tab("t1"), tab("t2"), tab("t9", workspace: "w2")],
                workspaceID: "w1",
                afterTabID: "t9"
            )
        )
    }

    func testIndexIsWithinWorkspaceStripNotGlobalList() {
        // Tabs from other spaces before the anchor must not inflate the index.
        XCTAssertEqual(
            NewTabPlacement.insertIndex(
                tabs: [
                    tab("a1", workspace: "w0"),
                    tab("a2", workspace: "w0"),
                    tab("t1"),
                    tab("t2"),
                ],
                workspaceID: "w1",
                afterTabID: "t1"
            ),
            1
        )
    }

    private func tab(_ id: String, workspace: String = "w1") -> HerdrTab {
        HerdrTab(
            tabID: id,
            workspaceID: workspace,
            number: 1,
            label: "",
            focused: false,
            paneCount: 1,
            agentStatus: .idle
        )
    }
}
