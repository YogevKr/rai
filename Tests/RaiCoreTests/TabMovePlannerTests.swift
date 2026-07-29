@testable import RaiCore
import XCTest

final class TabMovePlannerTests: XCTestCase {
    // MARK: plan

    func testSinglePaneTabPlansLeadWithoutFollowers() {
        let plan = TabMovePlanner.plan(
            tab: tab("t1", label: "api"),
            panes: [pane("p1")],
            layout: nil
        )
        XCTAssertEqual(
            plan,
            TabMovePlanner.Plan(
                leadPaneID: "p1",
                followerPaneIDs: [],
                carriedLabel: "api"
            )
        )
    }

    func testTabWithoutPanesHasNoPlan() {
        XCTAssertNil(
            TabMovePlanner.plan(
                tab: tab("t1", label: "api"),
                panes: [pane("p1", tab: "other")],
                layout: nil
            )
        )
    }

    func testPanesOfOtherTabsAreIgnored() {
        let plan = TabMovePlanner.plan(
            tab: tab("t1", label: "api"),
            panes: [pane("p9", tab: "other"), pane("p1"), pane("p2")],
            layout: nil
        )
        XCTAssertEqual(plan?.leadPaneID, "p1")
        XCTAssertEqual(plan?.followerPaneIDs, ["p2"])
    }

    // MARK: orderedPaneIDs

    func testLayoutOrdersPanesTopToBottomThenLeftToRight() {
        let layout = layout(
            tab: "t1",
            panes: [
                layoutPane("bottom-left", x: 0, y: 20),
                layoutPane("top-right", x: 40, y: 0),
                layoutPane("top-left", x: 0, y: 0),
            ]
        )
        XCTAssertEqual(
            TabMovePlanner.orderedPaneIDs(
                tabID: "t1",
                panes: [pane("bottom-left"), pane("top-right"), pane("top-left")],
                layout: layout
            ),
            ["top-left", "top-right", "bottom-left"]
        )
    }

    func testMissingLayoutFallsBackToSnapshotOrder() {
        XCTAssertEqual(
            TabMovePlanner.orderedPaneIDs(
                tabID: "t1",
                panes: [pane("p2"), pane("p1")],
                layout: nil
            ),
            ["p2", "p1"]
        )
    }

    func testLayoutOfAnotherTabFallsBackToSnapshotOrder() {
        XCTAssertEqual(
            TabMovePlanner.orderedPaneIDs(
                tabID: "t1",
                panes: [pane("p2"), pane("p1")],
                layout: layout(tab: "other", panes: [layoutPane("p1", x: 0, y: 0)])
            ),
            ["p2", "p1"]
        )
    }

    func testPanesAbsentFromLayoutKeepSnapshotOrderAtEnd() {
        let layout = layout(tab: "t1", panes: [layoutPane("p2", x: 0, y: 0)])
        XCTAssertEqual(
            TabMovePlanner.orderedPaneIDs(
                tabID: "t1",
                panes: [pane("p3"), pane("p2"), pane("p1")],
                layout: layout
            ),
            ["p2", "p3", "p1"]
        )
    }

    // MARK: carriedLabel

    func testCustomLabelIsCarriedTrimmed() {
        XCTAssertEqual(
            TabMovePlanner.carriedLabel(for: tab("t1", label: " api ")),
            "api"
        )
    }

    func testAutoNumberingLabelIsNotCarried() {
        XCTAssertNil(TabMovePlanner.carriedLabel(for: tab("t1", label: "3")))
        XCTAssertNil(TabMovePlanner.carriedLabel(for: tab("t1", label: "")))
        XCTAssertNil(TabMovePlanner.carriedLabel(for: tab("t1", label: "  ")))
    }

    // MARK: helpers

    private func tab(_ id: String, label: String) -> HerdrTab {
        HerdrTab(
            tabID: id,
            workspaceID: "w1",
            number: 1,
            label: label,
            focused: false,
            paneCount: 1,
            agentStatus: .idle
        )
    }

    private func pane(_ id: String, tab: String = "t1") -> Pane {
        Pane(
            paneID: id,
            terminalID: id,
            workspaceID: "w1",
            tabID: tab,
            focused: false,
            cwd: "/",
            foregroundCWD: nil,
            agent: nil,
            terminalTitle: nil,
            terminalTitleStripped: nil,
            agentStatus: .idle,
            revision: 0,
            scroll: nil
        )
    }

    private func layoutPane(_ id: String, x: Int, y: Int) -> PaneLayoutPane {
        PaneLayoutPane(
            paneID: id,
            focused: false,
            rect: PaneLayoutRect(x: x, y: y, width: 40, height: 20)
        )
    }

    private func layout(tab: String, panes: [PaneLayoutPane]) -> PaneLayoutSnapshot {
        PaneLayoutSnapshot(
            workspaceID: "w1",
            tabID: tab,
            zoomed: false,
            area: PaneLayoutRect(x: 0, y: 0, width: 80, height: 40),
            focusedPaneID: panes.first?.paneID ?? "",
            panes: panes,
            splits: []
        )
    }
}
