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
}
