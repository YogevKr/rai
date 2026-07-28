import XCTest
@testable import RaiApp

final class ScrolledPillDecisionTests: XCTestCase {
    func testShowsOnlyWhenScrolledIdleAndVisible() {
        XCTAssertTrue(ScrolledPillDecision.shouldShow(
            offsetFromBottom: 30, mouseIsDown: false, inWindow: true))
    }

    func testHiddenAtLiveTail() {
        XCTAssertFalse(ScrolledPillDecision.shouldShow(
            offsetFromBottom: 0, mouseIsDown: false, inWindow: true))
    }

    func testHiddenMidDrag() {
        // The selection engine scrolls during an edge-drag; a pill popping up
        // under the pointer mid-gesture is noise.
        XCTAssertFalse(ScrolledPillDecision.shouldShow(
            offsetFromBottom: 30, mouseIsDown: true, inWindow: true))
    }

    func testHiddenWhenDetachedFromWindow() {
        XCTAssertFalse(ScrolledPillDecision.shouldShow(
            offsetFromBottom: 30, mouseIsDown: false, inWindow: false))
    }
}

@MainActor
final class WheelDownBatchTests: XCTestCase {
    func testThreeLinesPerEvent() {
        XCTAssertEqual(ScrollbackSelectionController.wheelDownEvents(forOffset: 0), 0)
        XCTAssertEqual(ScrollbackSelectionController.wheelDownEvents(forOffset: 1), 1)
        XCTAssertEqual(ScrollbackSelectionController.wheelDownEvents(forOffset: 3), 1)
        XCTAssertEqual(ScrollbackSelectionController.wheelDownEvents(forOffset: 4), 2)
        XCTAssertEqual(ScrollbackSelectionController.wheelDownEvents(forOffset: 30), 10)
    }

    func testDeepScrollbackIsCapped() {
        // One batch is at most 50 events (150 lines); deeper offsets unwind
        // across returnToLive's feedback loop instead of one giant burst.
        XCTAssertEqual(ScrollbackSelectionController.wheelDownEvents(forOffset: 486), 50)
        XCTAssertEqual(ScrollbackSelectionController.wheelDownEvents(forOffset: 10_000), 50)
    }
}
