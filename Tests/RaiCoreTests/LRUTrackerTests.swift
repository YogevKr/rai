import RaiCore
import XCTest

final class LRUTrackerTests: XCTestCase {
    func testEvictsLeastRecentlyUsedKeyBeyondCapacity() {
        var tracker = LRUTracker<String>(capacity: 2)

        XCTAssertNil(tracker.touch("first"))
        XCTAssertNil(tracker.touch("second"))
        XCTAssertEqual(tracker.touch("third"), "first")
        XCTAssertEqual(tracker.leastToMostRecent, ["second", "third"])
    }

    func testTouchRefreshesExistingKeyRecency() {
        var tracker = LRUTracker<String>(capacity: 2)

        tracker.touch("first")
        tracker.touch("second")
        XCTAssertNil(tracker.touch("first"))
        XCTAssertEqual(tracker.touch("third"), "second")
        XCTAssertEqual(tracker.leastToMostRecent, ["first", "third"])
    }

    func testRemoveExcludesKeyFromFutureEviction() {
        var tracker = LRUTracker<String>(capacity: 2)

        tracker.touch("first")
        tracker.touch("second")
        tracker.remove("first")

        XCTAssertNil(tracker.touch("third"))
        XCTAssertEqual(tracker.leastToMostRecent, ["second", "third"])
    }

    /// The terminal pool re-bounds itself to the herd's pane count, so growing
    /// must keep every resident key and shrinking must surrender the oldest.
    func testGrowingCapacityEvictsNothing() {
        var tracker = LRUTracker<String>(capacity: 2)
        tracker.touch("first")
        tracker.touch("second")

        XCTAssertEqual(tracker.setCapacity(4), [])
        XCTAssertNil(tracker.touch("third"))
        XCTAssertNil(tracker.touch("fourth"))
        XCTAssertEqual(
            tracker.leastToMostRecent,
            ["first", "second", "third", "fourth"]
        )
    }

    func testShrinkingCapacityEvictsLeastRecentFirst() {
        var tracker = LRUTracker<String>(capacity: 4)
        for key in ["first", "second", "third", "fourth"] { tracker.touch(key) }

        XCTAssertEqual(tracker.setCapacity(2), ["first", "second"])
        XCTAssertEqual(tracker.leastToMostRecent, ["third", "fourth"])
        XCTAssertEqual(tracker.capacity, 2)
    }
}
