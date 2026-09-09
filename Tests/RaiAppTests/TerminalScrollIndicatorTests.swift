import AppKit
import RaiCore
import SwiftTerm
import XCTest
@testable import RaiApp

@MainActor
final class TerminalScrollIndicatorTests: XCTestCase {
    private func terminal() -> FocusAwareTerminalView {
        _ = NSApplication.shared
        let view = FocusAwareTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.feed(text: (0..<200).map { "line \($0)\r\n" }.joined())
        return view
    }

    func testScrollIndicatorDoesNotReserveColumnsOrChangeContent() throws {
        let view = terminal()
        let indicator = try XCTUnwrap(view.scrollIndicator)
        let reference = TerminalView(frame: view.frame)
        reference.subviews.compactMap { $0 as? NSScroller }.forEach { $0.isHidden = true }
        reference.setFrameSize(view.frame.size)
        let content = view.getTerminal().getBufferAsData()
        let size = view.getOptimalFrameSize()
        XCTAssertEqual(indicator.alphaValue, 0)
        indicator.noteScroll()
        XCTAssertEqual(indicator.alphaValue, 0.65)
        for width in [640.0, 431.0, 920.0] {
            view.setFrameSize(NSSize(width: width, height: 400))
            reference.setFrameSize(view.frame.size)
            XCTAssertEqual(view.getTerminal().cols, reference.getTerminal().cols)
            let cols = view.getTerminal().cols
            indicator.hide()
            view.setFrameSize(view.frame.size)
            XCTAssertEqual(view.getTerminal().cols, cols)
            indicator.noteScroll()
            view.setFrameSize(view.frame.size)
            XCTAssertEqual(view.getTerminal().cols, cols)
        }
        view.setFrameSize(NSSize(width: 640, height: 400))
        XCTAssertEqual(view.getOptimalFrameSize(), size)
        XCTAssertEqual(view.getTerminal().getBufferAsData(), content)
    }

    func testOnlyTheScrollingPaneShowsItsIndicatorAndItExpires() async throws {
        let view = terminal()
        let other = terminal()
        let indicator = try XCTUnwrap(view.scrollIndicator)
        indicator.noteScroll()
        XCTAssertEqual(other.scrollIndicator?.alphaValue, 0)
        try await Task.sleep(for: .milliseconds(400))
        indicator.noteScroll()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(indicator.alphaValue, 0.65)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(indicator.alphaValue, 0)
        view.feed(text: "more output\r\n")
        XCTAssertEqual(indicator.alphaValue, 0)
    }

    func testEmptyHistoryDoesNotShowIndicator() throws {
        _ = NSApplication.shared
        let view = FocusAwareTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let indicator = try XCTUnwrap(view.scrollIndicator)
        indicator.noteScroll()
        XCTAssertEqual(indicator.alphaValue, 0)
    }

    func testBuiltInScrollerStaysHiddenAfterOutputAndResize() throws {
        _ = NSApplication.shared
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let scrollers = view.subviews.compactMap { $0 as? NSScroller }
        XCTAssertFalse(scrollers.isEmpty)
        TerminalScrollIndicator.hideBuiltIn(in: view)
        view.feed(text: (0..<200).map { "line \($0)\r\n" }.joined())
        let content = view.getTerminal().getBufferAsData()
        for width in [431.0, 920.0, 640.0] {
            view.setFrameSize(NSSize(width: width, height: 400))
            view.layoutSubtreeIfNeeded()
            XCTAssertTrue(scrollers.allSatisfy(\.isHidden))
        }
        XCTAssertEqual(view.getTerminal().getBufferAsData(), content)
    }

    func testRemoteUpdatesPreserveTheThumbUntilTrackingEnds() throws {
        let view = terminal()
        let indicator = try XCTUnwrap(view.scrollIndicator)
        indicator.remoteScroll = PaneScroll(offsetFromBottom: 50, maxOffsetFromBottom: 200, viewportRows: 40)
        indicator.trackingKnob = true
        indicator.doubleValue = 0.25
        indicator.noteScroll()
        XCTAssertEqual(indicator.doubleValue, 0.25)
        indicator.remoteScroll = PaneScroll(offsetFromBottom: 100, maxOffsetFromBottom: 200, viewportRows: 40)
        XCTAssertEqual(indicator.doubleValue, 0.25)
        indicator.trackingKnob = false
        indicator.noteScroll()
        XCTAssertEqual(indicator.doubleValue, 0.5)
    }

    func testRepeatedSnapshotDoesNotReplaceNewerScrollEvents() throws {
        let view = terminal()
        let indicator = try XCTUnwrap(view.scrollIndicator)
        let snapshot = PaneScroll(offsetFromBottom: 50, maxOffsetFromBottom: 200, viewportRows: 40)
        indicator.snapshotScroll = snapshot
        indicator.remoteScroll = PaneScroll(offsetFromBottom: 150, maxOffsetFromBottom: 200, viewportRows: 40)
        indicator.snapshotScroll = snapshot
        XCTAssertEqual(indicator.doubleValue, 0.25)
        indicator.snapshotScroll = PaneScroll(offsetFromBottom: 100, maxOffsetFromBottom: 200, viewportRows: 40)
        XCTAssertEqual(indicator.doubleValue, 0.5)
    }

    func testInputOutsideTheKeyMonitorCancelsPendingScrolling() async throws {
        let view = terminal()
        let controller = view.scrollbackSelection
        controller.client = HerdrClient(socketPath: "/tmp/rai-absent-\(UUID().uuidString).sock")
        controller.paneID = "w1:p1"
        defer { controller.paneID = nil }
        let actions: [(FocusAwareTerminalView) -> Void] = [
            { $0.paste(self) },
            { $0.insertText("text", replacementRange: NSRange(location: NSNotFound, length: 0)) },
            { $0.send(source: $0, data: [0x61][...]) },
            { $0.beginExternalInput(); $0.endExternalInput() }
        ]
        for action in actions {
            controller.scroll(toPosition: 0.25)
            let pending = try XCTUnwrap(controller.indicatorScrollTask)
            XCTAssertFalse(pending.isCancelled)
            action(view)
            XCTAssertTrue(pending.isCancelled)
            XCTAssertNil(controller.indicatorScrollTask)
            await pending.value
        }
    }

    func testHerdrScrollbackUsesServerMetricsWithoutLocalHistory() throws {
        _ = NSApplication.shared
        let view = FocusAwareTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let indicator = try XCTUnwrap(view.scrollIndicator)
        XCTAssertFalse(view.canScroll)
        indicator.remoteScroll = PaneScroll(offsetFromBottom: 50, maxOffsetFromBottom: 200, viewportRows: 40)
        XCTAssertTrue(indicator.isHidden, "Server output alone must not reveal the indicator")
        let cols = view.getTerminal().cols
        indicator.noteScroll()
        XCTAssertFalse(indicator.isHidden)
        XCTAssertTrue(indicator.isEnabled)
        XCTAssertEqual(indicator.doubleValue, 0.75, accuracy: 0.001)
        XCTAssertEqual(indicator.knobProportion, 1.0 / 6, accuracy: 0.001)
        indicator.hide()
        view.setFrameSize(view.frame.size)
        XCTAssertEqual(view.getTerminal().cols, cols)
        indicator.remoteScroll = PaneScroll(offsetFromBottom: 0, maxOffsetFromBottom: 0, viewportRows: 40)
        indicator.noteScroll()
        XCTAssertTrue(indicator.isHidden)
    }
}
