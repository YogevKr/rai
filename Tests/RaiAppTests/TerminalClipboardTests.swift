import AppKit
import SwiftTerm
import XCTest
@testable import RaiApp

@MainActor
final class TerminalClipboardTests: XCTestCase {
    private func terminal() -> FocusAwareTerminalView {
        _ = NSApplication.shared
        let view = FocusAwareTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        view.feed(text: "COPY THIS")
        view.setSelectionRange(start: Position(col: 0, row: 0), end: Position(col: 4, row: 0))
        return view
    }

    func testFailedGestureCopyKeepsSelectionAndReportsFailure() async throws {
        let view = terminal()
        let before = view.getSelection()
        var notices: [String] = []
        view.scrollbackSelection.onNotice = { notices.append($0) }
        view.clipboardWriter = { _ in false }
        XCTAssertFalse(view.copyToClipboard("COPY"))
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(view.getSelection(), before)
        XCTAssertNotNil(view.getSelectionRange())
        XCTAssertEqual(notices, ["Copy failed. The selection remains available."])
    }

    func testKeyboardCopyFailureDoesNotClaimSuccessOrChangeText() {
        let view = terminal()
        let before = view.getTerminal().getBufferAsData()
        var notices: [String] = []
        view.scrollbackSelection.onNotice = { notices.append($0) }
        var copied: [String] = []
        view.clipboardWriter = { copied.append($0); return false }
        view.copy(self)
        XCTAssertEqual(copied, ["COPY"])
        XCTAssertEqual(notices, ["Copy failed. The selection remains available."])
        XCTAssertNotNil(view.getSelectionRange())
        XCTAssertEqual(view.getTerminal().getBufferAsData(), before)
    }

    func testSuccessfulGestureCopyClearsOnlyAfterWriting() async throws {
        let view = terminal()
        var captured: String?
        view.clipboardWriter = { captured = $0; return true }
        XCTAssertTrue(view.copyToClipboard("COPY"))
        XCTAssertEqual(captured, "COPY")
        XCTAssertNotNil(view.getSelectionRange())
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertNil(view.getSelectionRange())
    }

    func testCompletedCopyDoesNotClearANewerSelection() async throws {
        let view = terminal()
        view.clipboardWriter = { _ in true }
        XCTAssertTrue(view.copyToClipboard("COPY"))
        view.setSelectionRange(start: Position(col: 5, row: 0), end: Position(col: 9, row: 0))
        let selected = view.getSelection()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(view.getSelection(), selected)
        XCTAssertEqual(view.getSelectionRange()?.start, Position(col: 5, row: 0))
    }
}
