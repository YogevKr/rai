import XCTest

@testable import RaiCore

final class TerminalFeedRepaintTests: XCTestCase {
    func testSmallFocusedVisibleFeedBypassesThrottle() {
        var repaintCount = 0

        let repainted = TerminalFeedRepaintPolicy.repaintIfNeeded(
            byteCount: TerminalFeedRepaintPolicy.immediateByteLimit - 1,
            isFocused: true,
            isVisible: true,
            hasRecentUnpaintedUserInput: true,
            synchronizedOutputActive: false
        ) {
            repaintCount += 1
        }

        XCTAssertTrue(repainted)
        XCTAssertEqual(repaintCount, 1)
    }

    func testLargeFeedKeepsThrottle() {
        var repaintCount = 0

        let repainted = TerminalFeedRepaintPolicy.repaintIfNeeded(
            byteCount: TerminalFeedRepaintPolicy.immediateByteLimit,
            isFocused: true,
            isVisible: true,
            hasRecentUnpaintedUserInput: true,
            synchronizedOutputActive: false
        ) {
            repaintCount += 1
        }

        XCTAssertFalse(repainted)
        XCTAssertEqual(repaintCount, 0)
    }

    func testHiddenOrUnfocusedFeedKeepsThrottle() {
        for (focused, visible) in [(false, true), (true, false), (false, false)] {
            var repaintCount = 0
            let repainted = TerminalFeedRepaintPolicy.repaintIfNeeded(
                byteCount: 1,
                isFocused: focused,
                isVisible: visible,
                hasRecentUnpaintedUserInput: true,
                synchronizedOutputActive: false
            ) {
                repaintCount += 1
            }
            XCTAssertFalse(repainted)
            XCTAssertEqual(repaintCount, 0)
        }
    }

    func testSynchronizedOutputKeepsThrottle() {
        var repaintCount = 0
        let repainted = TerminalFeedRepaintPolicy.repaintIfNeeded(
            byteCount: 1,
            isFocused: true,
            isVisible: true,
            hasRecentUnpaintedUserInput: true,
            synchronizedOutputActive: true
        ) {
            repaintCount += 1
        }

        XCTAssertFalse(repainted)
        XCTAssertEqual(repaintCount, 0)
    }

    func testSmallStreamWithoutRecentInputKeepsThrottle() {
        var repaintCount = 0
        let repainted = TerminalFeedRepaintPolicy.repaintIfNeeded(
            byteCount: 1,
            isFocused: true,
            isVisible: true,
            hasRecentUnpaintedUserInput: false,
            synchronizedOutputActive: false
        ) {
            repaintCount += 1
        }

        XCTAssertFalse(repainted)
        XCTAssertEqual(repaintCount, 0)
    }

    func testOnlyOneRepaintRunsForEachInputEvent() {
        var state = TerminalFeedRepaintState()
        var repaintCount = 0
        let inputTime: UInt64 = 1_000_000_000
        state.noteUserInput(at: inputTime)

        for offset in [1_000_000, 2_000_000, 3_000_000] {
            state.repaintIfNeeded(
                byteCount: 1,
                isFocused: true,
                isVisible: true,
                synchronizedOutputActive: false,
                at: inputTime + UInt64(offset)
            ) {
                repaintCount += 1
            }
        }
        XCTAssertEqual(repaintCount, 1)

        state.noteUserInput(at: inputTime + 10_000_000)
        state.repaintIfNeeded(
            byteCount: 1,
            isFocused: true,
            isVisible: true,
            synchronizedOutputActive: false,
            at: inputTime + 11_000_000
        ) {
            repaintCount += 1
        }
        XCTAssertEqual(repaintCount, 2)
    }

    func testInputOlderThanWindowKeepsThrottle() {
        var state = TerminalFeedRepaintState()
        var repaintCount = 0
        let inputTime: UInt64 = 1_000_000_000
        state.noteUserInput(at: inputTime)

        let repainted = state.repaintIfNeeded(
            byteCount: 1,
            isFocused: true,
            isVisible: true,
            synchronizedOutputActive: false,
            at: inputTime + TerminalFeedRepaintState.recentInputWindowNanoseconds + 1
        ) {
            repaintCount += 1
        }

        XCTAssertFalse(repainted)
        XCTAssertEqual(repaintCount, 0)
    }
}
