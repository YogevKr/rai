import XCTest
@testable import RaiCore

final class TabShapePlannerTests: XCTestCase {
    func testSingleLeafNeedsNoSteps() {
        XCTAssertEqual(TabShapePlanner.steps(for: .pane("p1")), [])
    }

    func testTwoPaneSplitReplaysTheRecordedRatioVerbatim() {
        // herdr stores the FIRST child's share, and `pane split --ratio` means
        // the same thing, so 0.7 goes back out as 0.7.
        let tree = PaneLayoutNode.split(
            id: "s1",
            direction: .right,
            ratio: 0.7,
            first: .pane("a"),
            second: .pane("b")
        )
        XCTAssertEqual(
            TabShapePlanner.steps(for: tree),
            [TabRebuildStep(anchorLeaf: 0, newLeaf: 1, direction: .right, ratio: 0.7)]
        )
    }

    func testNestedTreeEmitsOuterSplitFirstWithFirstLeafAnchors() {
        // ((a | b) / c): the tab is divided top/bottom first, then the top
        // half is divided left/right. Replay must follow that order — the
        // outer region has to exist before it can be subdivided — and each
        // split targets the pane that currently occupies its region, which is
        // always the region's first leaf.
        let tree = PaneLayoutNode.split(
            id: "outer",
            direction: .down,
            ratio: 0.6,
            first: .split(
                id: "inner",
                direction: .right,
                ratio: 0.5,
                first: .pane("a"),
                second: .pane("b")
            ),
            second: .pane("c")
        )
        XCTAssertEqual(
            TabShapePlanner.steps(for: tree),
            [
                TabRebuildStep(anchorLeaf: 0, newLeaf: 2, direction: .down, ratio: 0.6),
                TabRebuildStep(anchorLeaf: 0, newLeaf: 1, direction: .right, ratio: 0.5),
            ]
        )
    }

    func testRightHeavyTreeAnchorsOnEachRegionsFirstLeaf() {
        // (a | (b / c)): the second region's splits anchor on b, not a.
        let tree = PaneLayoutNode.split(
            id: "outer",
            direction: .right,
            ratio: 0.4,
            first: .pane("a"),
            second: .split(
                id: "inner",
                direction: .down,
                ratio: 0.5,
                first: .pane("b"),
                second: .pane("c")
            )
        )
        XCTAssertEqual(
            TabShapePlanner.steps(for: tree),
            [
                TabRebuildStep(anchorLeaf: 0, newLeaf: 1, direction: .right, ratio: 0.4),
                TabRebuildStep(anchorLeaf: 1, newLeaf: 2, direction: .down, ratio: 0.5),
            ]
        )
    }
}
