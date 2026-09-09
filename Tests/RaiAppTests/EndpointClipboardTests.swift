import SwiftTerm
import XCTest
#if os(macOS)
import AppKit
@testable import RaiApp
#else
import UIKit
@testable import rai
#endif

@MainActor
final class EndpointClipboardTests: XCTestCase {
    func testNativeCopyFailureKeepsSelectionDuringOutputAndAllowsExplicitRetry() {
        #if os(macOS)
        _ = NSApplication.shared
        let terminal = EndpointTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        #else
        let terminal = EndpointPhoneTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        #endif
        let input = ClipboardInputRecorder()
        terminal.terminalDelegate = input
        // Match the endpoint renderer: Rai handles mouse reports outside SwiftTerm.
        terminal.allowMouseReporting = false
        var accept = false
        var writes: [String] = []
        let clipboard = EndpointClipboard { writes.append($0); return accept }
        terminal.clipboard = clipboard
        terminal.feed(text: "COPY THIS\r\n")
        terminal.setSelectionRange(start: Position(col: 0, row: 0), end: Position(col: 4, row: 0))
        let content = terminal.getTerminal().getBufferAsData()
        let sent = input.bytes
        terminal.copy(self)
        XCTAssertEqual(writes, ["COPY"])
        XCTAssertEqual(clipboard.message, EndpointClipboard.failureMessage)
        XCTAssertEqual(terminal.getSelection(), "COPY")
        XCTAssertEqual(terminal.getSelectionRange()?.start, Position(col: 0, row: 0))
        XCTAssertEqual(terminal.getSelectionRange()?.end, Position(col: 4, row: 0))
        XCTAssertEqual(terminal.getTerminal().getBufferAsData(), content)
        XCTAssertEqual(input.bytes, sent, "Copy failure must not send an interrupt or terminal input.")

        terminal.feed(text: "\u{1b}[5;1HOUTPUT CONTINUES")
        XCTAssertEqual(terminal.getSelection(), "COPY")
        XCTAssertEqual(writes.count, 1, "Output must not retry the clipboard write.")
        accept = true
        terminal.copy(self)
        XCTAssertEqual(writes, ["COPY", "COPY"])
        XCTAssertNil(clipboard.message)
        XCTAssertEqual(terminal.getSelection(), "COPY")
        XCTAssertEqual(input.bytes, sent)
    }

    func testHistoryCopyKeepsExactUnicodeSelectionOnFailureAndRetry() {
        #if os(macOS)
        _ = NSApplication.shared
        #endif
        let view = EndpointSelectableTextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let selected = "👩🏽‍💻 é  \n"
        let text = "before " + selected + "after"
        let range = (text as NSString).range(of: selected)
        #if os(macOS)
        view.string = text
        view.setSelectedRange(range)
        #else
        view.text = text
        view.selectedRange = range
        #endif
        var accept = false
        var writes: [String] = []
        let clipboard = EndpointClipboard { writes.append($0); return accept }
        view.clipboard = clipboard
        view.copy(self)
        XCTAssertEqual(writes, [selected])
        XCTAssertEqual(clipboard.message, EndpointClipboard.failureMessage)
        #if os(macOS)
        XCTAssertEqual(view.selectedRange(), range)
        XCTAssertEqual(view.string, text)
        #else
        XCTAssertEqual(view.selectedRange, range)
        XCTAssertEqual(view.text, text)
        #endif
        accept = true
        view.copy(self)
        XCTAssertEqual(writes, [selected, selected])
        XCTAssertNil(clipboard.message)
    }

    func testCapturedMotionsPreserveUnicodeAndReverseTheActiveSelectionEdge() {
        #if os(macOS)
        _ = NSApplication.shared
        #endif
        let view = EndpointSelectableTextView(frame: CGRect(x: 0, y: 0, width: 800, height: 300))
        let text = "👩🏽‍💻 é words\nsecond line"
        let first = (text as NSString).range(of: "👩🏽‍💻")
        #if os(macOS)
        view.string = text
        view.setSelectedRange(NSRange(location: 0, length: 0))
        #else
        view.text = text
        view.selectedRange = NSRange(location: 0, length: 0)
        #endif
        view.isEditable = false
        view.isSelectable = true
        var writes: [String] = []
        view.clipboard = EndpointClipboard { writes.append($0); return true }
        view.moveSelection(.characterForward, extending: true)
        view.copy(nil)
        XCTAssertEqual(writes, ["👩🏽‍💻"])
        view.moveSelection(.characterBackward, extending: true)
        #if os(macOS)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 0))
        #else
        XCTAssertEqual(view.selectedRange, NSRange(location: 0, length: 0))
        #endif
        view.moveSelection(.characterForward, extending: false)
        view.moveSelection(.documentEnd, extending: true)
        view.copy(nil)
        XCTAssertEqual(writes.last, (text as NSString).substring(from: NSMaxRange(first)))
        #if os(macOS)
        XCTAssertEqual(view.string, text)
        #else
        XCTAssertEqual(view.text, text)
        #endif
    }

    func testCapturedWordAndLineMotionsRespectExternalSelectionChanges() {
        #if os(macOS)
        _ = NSApplication.shared
        #endif
        let view = EndpointSelectableTextView(frame: CGRect(x: 0, y: 0, width: 800, height: 300))
        let text = "first word\nsecond line"
        #if os(macOS)
        view.string = text
        view.setSelectedRange(NSRange(location: 0, length: 0))
        #else
        view.text = text
        view.selectedRange = NSRange(location: 0, length: 0)
        #endif
        view.isEditable = false
        view.isSelectable = true
        var writes: [String] = []
        view.clipboard = EndpointClipboard { writes.append($0); return true }
        view.moveSelection(.wordForward, extending: true)
        view.copy(nil)
        XCTAssertEqual(writes, ["first"])
        let second = (text as NSString).range(of: "second")
        #if os(macOS)
        view.setSelectedRange(NSRange(location: second.location, length: 0))
        #else
        view.selectedRange = NSRange(location: second.location, length: 0)
        #endif
        view.moveSelection(.lineEnd, extending: true)
        view.copy(nil)
        XCTAssertEqual(writes.last, "second line")
        view.moveSelection(.documentStart, extending: false)
        view.moveSelection(.documentEnd, extending: true)
        view.copy(nil)
        XCTAssertEqual(writes.last, text)
    }

    func testCopyWithoutSelectionDoesNotWriteOrSendInput() {
        #if os(macOS)
        _ = NSApplication.shared
        let terminal = EndpointTerminalView(frame: .zero)
        #else
        let terminal = EndpointPhoneTerminalView(frame: .zero)
        #endif
        let input = ClipboardInputRecorder()
        terminal.terminalDelegate = input
        terminal.clipboard = EndpointClipboard { _ in XCTFail("No selected text exists"); return false }
        terminal.copy(self)
        XCTAssertNil(terminal.clipboard.message)
        XCTAssertTrue(input.bytes.isEmpty)
    }

    #if os(iOS)
    func testPhoneOptionDeadKeysSendOnlyCommittedText() {
        let terminal = EndpointPhoneTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let recorder = ClipboardInputRecorder()
        terminal.terminalDelegate = recorder
        terminal.semanticInput = { _ in XCTFail("A dead key is not semantic terminal input") }
        XCTAssertFalse(terminal.optionAsMetaKey)
        for (key, committed) in [("e", "é"), ("u", "ü")] {
            let press = CompositionPress(character: key)
            let before = recorder.bytes
            terminal.pressesBegan([press], with: nil)
            terminal.pressesEnded([press], with: nil)
            XCTAssertEqual(recorder.bytes, before, "The Option dead key must stay in UIKit.")
            terminal.insertText(committed)
            XCTAssertEqual(recorder.bytes, before + Array(committed.utf8))
        }
        XCTAssertEqual(recorder.bytes, Array("éü".utf8))
    }

    func testUIKitWriteProducesChangedCountAndExactNamedPasteboardText() throws {
        let name = UIPasteboard.Name("rai.clipboard.tests.\(UUID())")
        let board = try XCTUnwrap(UIPasteboard(name: name, create: true))
        defer { UIPasteboard.remove(withName: name) }
        let text = "Clipboard 👩🏽‍💻 é  \n"
        XCTAssertTrue(EndpointClipboard.writeUIKitClipboard(text, to: board))
        XCTAssertEqual(board.string, text)
        XCTAssertTrue(EndpointClipboard.writeUIKitClipboard(text, to: board), "Repeated explicit writes still need a receipt.")
    }
    #endif

    #if DEBUG
    func testFailureFlagRequiresAnExplicitLabBundleAndValue() {
        for identifier in [nil, "gr.krig.rai", "com.whetstone.rai.ios", "unrelated.lab.app"] {
            XCTAssertFalse(EndpointClipboard.requestsLabFailure(bundleIdentifier: identifier,
                environment: ["RAI_LAB_FAIL_NEXT_COPY": "1"]))
        }
        for identifier in ["gr.krig.rai.lab.e2e-fixture", "com.whetstone.rai.ios.lab.e2e-fixture"] {
            XCTAssertFalse(EndpointClipboard.requestsLabFailure(bundleIdentifier: identifier, environment: [:]))
            XCTAssertFalse(EndpointClipboard.requestsLabFailure(bundleIdentifier: identifier,
                environment: ["RAI_LAB_FAIL_NEXT_COPY": "true"]))
            XCTAssertTrue(EndpointClipboard.requestsLabFailure(bundleIdentifier: identifier,
                environment: ["RAI_LAB_FAIL_NEXT_COPY": "1"]))
        }
    }
    #endif
}

private final class ClipboardInputRecorder: TerminalViewDelegate {
    var bytes: [UInt8] = []
    func send(source: TerminalView, data: ArraySlice<UInt8>) { bytes.append(contentsOf: data) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    #if os(iOS)
    func setTerminalIconTitle(source: TerminalView, title: String) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    #endif
}

#if os(iOS)
private final class CompositionKey: UIKey {
    let character: String
    init(character: String) { self.character = character; super.init() }
    required init?(coder: NSCoder) { fatalError("Test fixture does not decode") }
    override var characters: String { "" }
    override var charactersIgnoringModifiers: String { character }
    override var modifierFlags: UIKeyModifierFlags { .alternate }
    override var keyCode: UIKeyboardHIDUsage { character == "e" ? .keyboardE : .keyboardU }
}

private final class CompositionPress: UIPress {
    let compositionKey: CompositionKey
    init(character: String) { compositionKey = CompositionKey(character: character); super.init() }
    override var key: UIKey? { compositionKey }
}
#endif
