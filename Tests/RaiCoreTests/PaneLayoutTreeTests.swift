import XCTest

@testable import RaiCore

/// Rect shapes here are real herdr protocol-16 snapshots (the tab area is
/// offset by herdr's own sidebar, which is why x starts at 26).
final class PaneLayoutTreeTests: XCTestCase {
    private func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> PaneLayoutRect {
        PaneLayoutRect(x: x, y: y, width: w, height: h)
    }

    private func snapshot(
        area: PaneLayoutRect,
        panes: [(String, PaneLayoutRect)],
        splits: [(String, SplitDirection, Double, PaneLayoutRect)]
    ) -> PaneLayoutSnapshot {
        PaneLayoutSnapshot(
            workspaceID: "w1",
            tabID: "w1:t1",
            zoomed: false,
            area: area,
            focusedPaneID: panes.first?.0 ?? "",
            panes: panes.map {
                PaneLayoutPane(paneID: $0.0, focused: false, rect: $0.1)
            },
            splits: splits.map {
                PaneLayoutSplit(id: $0.0, direction: $0.1, ratio: $0.2, rect: $0.3)
            }
        )
    }

    func testSinglePaneIsALeaf() {
        let layout = snapshot(
            area: rect(26, 1, 54, 23),
            panes: [("w1:p1", rect(26, 1, 54, 23))],
            splits: []
        )
        XCTAssertEqual(PaneLayoutTreeBuilder.build(from: layout), .pane("w1:p1"))
    }

    func testSplitRightKeepsPaneOrder() {
        let layout = snapshot(
            area: rect(26, 1, 54, 23),
            panes: [
                ("w1:p1", rect(26, 1, 27, 23)),
                ("w1:p2", rect(53, 1, 27, 23)),
            ],
            splits: [("split_0_root", .right, 0.5, rect(26, 1, 54, 23))]
        )
        XCTAssertEqual(
            PaneLayoutTreeBuilder.build(from: layout),
            .split(
                id: "split_0_root",
                direction: .right,
                ratio: 0.5,
                first: .pane("w1:p1"),
                second: .pane("w1:p2")
            )
        )
    }

    func testSplitDownKeepsPaneOrder() {
        let layout = snapshot(
            area: rect(26, 1, 54, 23),
            panes: [
                ("w1:p1", rect(26, 1, 54, 12)),
                ("w1:p2", rect(26, 13, 54, 11)),
            ],
            splits: [("split_0_root", .down, 0.5, rect(26, 1, 54, 23))]
        )
        XCTAssertEqual(
            PaneLayoutTreeBuilder.build(from: layout),
            .split(
                id: "split_0_root",
                direction: .down,
                ratio: 0.5,
                first: .pane("w1:p1"),
                second: .pane("w1:p2")
            )
        )
    }

    func testNestedSplitBuildsATree() {
        // Top pane full width; bottom half split into two columns.
        let layout = snapshot(
            area: rect(26, 1, 54, 23),
            panes: [
                ("w1:p1", rect(26, 1, 54, 12)),
                ("w1:p6", rect(26, 13, 27, 11)),
                ("w1:p7", rect(53, 13, 27, 11)),
            ],
            splits: [
                ("split_0_root", .down, 0.5, rect(26, 1, 54, 23)),
                ("split_1_1", .right, 0.5, rect(26, 13, 54, 11)),
            ]
        )
        XCTAssertEqual(
            PaneLayoutTreeBuilder.build(from: layout),
            .split(
                id: "split_0_root",
                direction: .down,
                ratio: 0.5,
                first: .pane("w1:p1"),
                second: .split(
                    id: "split_1_1",
                    direction: .right,
                    ratio: 0.5,
                    first: .pane("w1:p6"),
                    second: .pane("w1:p7")
                )
            )
        )
    }

    func testEveryPaneAppearsExactlyOnce() {
        let layout = snapshot(
            area: rect(26, 1, 54, 23),
            panes: [
                ("w1:p1", rect(26, 1, 54, 12)),
                ("w1:p6", rect(26, 13, 27, 11)),
                ("w1:p7", rect(53, 13, 27, 11)),
            ],
            splits: [
                ("split_0_root", .down, 0.5, rect(26, 1, 54, 23)),
                ("split_1_1", .right, 0.5, rect(26, 13, 54, 11)),
            ]
        )
        let ids = PaneLayoutTreeBuilder.build(from: layout)?.paneIDs ?? []
        XCTAssertEqual(ids.sorted(), ["w1:p1", "w1:p6", "w1:p7"])
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testEmptyLayoutHasNoTree() {
        let layout = snapshot(area: rect(0, 0, 80, 24), panes: [], splits: [])
        XCTAssertNil(PaneLayoutTreeBuilder.build(from: layout))
    }

    /// Rects that do not reconcile with the reported splits must fall through
    /// to the caller's absolute-positioning path instead of dropping a pane.
    func testUnreconcilableLayoutFallsThrough() {
        let layout = snapshot(
            area: rect(0, 0, 80, 24),
            panes: [
                ("w1:p1", rect(0, 0, 30, 24)),
                ("w1:p2", rect(50, 0, 30, 24)),
            ],
            splits: []
        )
        XCTAssertNil(PaneLayoutTreeBuilder.build(from: layout))
    }
}
