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

    func testClipboardImageIsWrittenAsPNGForPathPaste() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("rai.tests.\(UUID().uuidString)"))
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([image]))

        let view = terminal()
        let recorder = ImagePasteRecorder(frame: .zero)
        view.terminalDelegate = recorder
        view.pasteboard = pasteboard
        view.feed(text: "\u{1B}[?2004h")
        view.paste(self)
        let sent = String(decoding: recorder.bytes, as: UTF8.self)
        XCTAssertTrue(sent.hasPrefix("\u{1B}[200~"))
        XCTAssertTrue(sent.hasSuffix(" \u{1B}[201~"))
        XCTAssertFalse(recorder.bytes.contains(0x16))
        let path = String(sent.dropFirst(6).dropLast(7))
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertNotNil(NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: path))))
    }
}

@MainActor
private final class ImagePasteRecorder: TerminalProcessView {
    var bytes: [UInt8] = []
    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        bytes.append(contentsOf: data)
    }
}
