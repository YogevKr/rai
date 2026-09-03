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

    func testPostFeedSynchronizedOutputCancelsImmediateRepaint() {
        XCTAssertFalse(
            TerminalFeedRepaintPolicy.allowsImmediateRepaintAfterFeed(
                requested: true,
                synchronizedOutputActive: true
            )
        )
        XCTAssertTrue(
            TerminalFeedRepaintPolicy.allowsImmediateRepaintAfterFeed(
                requested: true,
                synchronizedOutputActive: false
            )
        )
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

    func testImmediateRepaintRunsAtMostOncePerFrame() {
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

        state.noteUserInput(at: inputTime + 17_000_000)
        state.repaintIfNeeded(
            byteCount: 1,
            isFocused: true,
            isVisible: true,
            synchronizedOutputActive: false,
            at: inputTime + 18_000_000
        ) {
            repaintCount += 1
        }
        XCTAssertEqual(repaintCount, 2)
    }

    func testSmallFeedInsideFrameIsDeferredBeforeFeed() {
        var state = TerminalFeedRepaintState()
        let inputTime: UInt64 = 1_000_000_000
        state.noteUserInput(at: inputTime)
        XCTAssertEqual(
            state.disposition(
                byteCount: 1,
                isFocused: true,
                isVisible: true,
                synchronizedOutputActive: false,
                at: inputTime + 1_000_000
            ),
            .feedNowAndRepaint
        )

        state.noteUserInput(at: inputTime + 2_000_000)
        XCTAssertEqual(
            state.disposition(
                byteCount: 1,
                isFocused: true,
                isVisible: true,
                synchronizedOutputActive: false,
                at: inputTime + 3_000_000
            ),
            .deferToFrame(deadlineUptimeNanoseconds: inputTime + 17_700_000)
        )
    }

    func testLargeFeedIsDeferredBeforeSwiftTermCanRepaintIt() {
        var state = TerminalFeedRepaintState()
        let inputTime: UInt64 = 1_000_000_000
        state.noteUserInput(at: inputTime)

        XCTAssertEqual(
            state.disposition(
                byteCount: 128 * 1024,
                isFocused: true,
                isVisible: true,
                synchronizedOutputActive: false,
                at: inputTime + 1_000_000
            ),
            .deferToFrame(
                deadlineUptimeNanoseconds: inputTime + 17_700_000
            )
        )

        state.noteDeferredFramePaint(at: inputTime + 17_700_000)
        XCTAssertEqual(
            state.disposition(
                byteCount: 128 * 1024,
                isFocused: true,
                isVisible: true,
                synchronizedOutputActive: false,
                at: inputTime + 18_000_000
            ),
            .deferToFrame(
                deadlineUptimeNanoseconds: inputTime + 34_400_000
            )
        )
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
