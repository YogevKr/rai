import RaiCore
import XCTest

@testable import RaiApp

/// herdr reports a zoomed tab with its *unzoomed* pane rects — `zoomed` is the
/// only signal. Rendering the layout verbatim left every pane at its split size,
/// so ⌘⇧↩ produced a "Zoomed" badge and no zoom.
final class ZoomedPaneLayoutTests: XCTestCase {
    private func layout(
        zoomed: Bool,
        focusedPaneID: String,
        panes: [(String, Bool)]
    ) -> PaneLayoutSnapshot {
        PaneLayoutSnapshot(
            workspaceID: "w1",
            tabID: "w1:t1",
            zoomed: zoomed,
            area: PaneLayoutRect(x: 0, y: 0, width: 80, height: 24),
            focusedPaneID: focusedPaneID,
            panes: panes.enumerated().map { index, pane in
                PaneLayoutPane(
                    paneID: pane.0,
                    focused: pane.1,
                    rect: PaneLayoutRect(x: index * 40, y: 0, width: 40, height: 24)
                )
            },
            splits: []
        )
    }

    func testZoomedTabRendersOnlyTheFocusedPane() {
        let snapshot = layout(
            zoomed: true,
            focusedPaneID: "w1:p2",
            panes: [("w1:p1", false), ("w1:p2", true)]
        )
        XCTAssertEqual(PaneLayoutView.zoomedPaneID(in: snapshot), "w1:p2")
    }

    func testUnzoomedTabKeepsTheFullLayout() {
        let snapshot = layout(
            zoomed: false,
            focusedPaneID: "w1:p2",
            panes: [("w1:p1", false), ("w1:p2", true)]
        )
        XCTAssertNil(PaneLayoutView.zoomedPaneID(in: snapshot))
    }

    func testZoomIsMeaninglessWithASinglePane() {
        let snapshot = layout(
            zoomed: true,
            focusedPaneID: "w1:p1",
            panes: [("w1:p1", true)]
        )
        XCTAssertNil(PaneLayoutView.zoomedPaneID(in: snapshot))
    }

    /// A stale `focused_pane_id` must not blank the tab: fall back to the pane
    /// the layout itself marks focused.
    func testFallsBackToTheLayoutsFocusedPane() {
        let snapshot = layout(
            zoomed: true,
            focusedPaneID: "w1:pGone",
            panes: [("w1:p1", false), ("w1:p2", true)]
        )
        XCTAssertEqual(PaneLayoutView.zoomedPaneID(in: snapshot), "w1:p2")
    }
}
