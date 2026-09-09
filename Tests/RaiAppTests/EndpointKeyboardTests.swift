import AppKit
import XCTest
import RaiCore
import SwiftTerm
@testable import RaiApp

final class EndpointKeyboardTests: XCTestCase {
    @MainActor
    func testUnicodeKeysUseLiteralTextWhileCompositionKeepsAppKitOwnership() throws {
        let view = EndpointTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertFalse(view.optionAsMetaKey, "AppKit must receive Option dead keys for keyboard composition.")
        let recorder = TextRecorder()
        view.terminalDelegate = recorder
        let text = "שלום é 👋"
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, characters: text,
            charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0))
        XCTAssertTrue(view.handleInterceptedKey(event))
        XCTAssertEqual(String(decoding: recorder.bytes, as: UTF8.self), text)
        view.setMarkedText("draft", selectedRange: NSRange(location: 5, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(view.handleInterceptedKey(event))
        XCTAssertEqual(String(decoding: recorder.bytes, as: UTF8.self), text)
    }

    @MainActor
    func testAttributedTextCommitsOnceAndClearsComposition() {
        let view = EndpointTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let recorder = TextRecorder()
        view.terminalDelegate = recorder
        let text = "hello שלום é 👋"
        view.setMarkedText(NSAttributedString(string: "draft"), selectedRange: NSRange(location: 5, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText(NSAttributedString(string: text), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(String(decoding: recorder.bytes, as: UTF8.self), text)
        XCTAssertFalse(view.hasMarkedText())
    }

    @MainActor
    func testControlKeysUseSemanticEventsAndComposedTextStaysWithAppKit() throws {
        func event(_ code: UInt16, _ text: String, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil, characters: text,
                charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        }
        XCTAssertEqual(EndpointKeyboard.key(for: try event(126, ""))?.code, .special(.up))
        XCTAssertEqual(EndpointKeyboard.key(for: try event(48, "\t", flags: .shift))?.code, .special(.backTab))
        XCTAssertEqual(EndpointKeyboard.key(for: try event(8, "c", flags: .control))?.modifiers, 2)
        XCTAssertEqual(EndpointKeyboard.key(for: try event(122, ""))?.code, .function(1))
        XCTAssertNil(EndpointKeyboard.key(for: try event(0, "א")))
        XCTAssertNil(EndpointKeyboard.key(for: try event(14, "é", flags: .option)))
    }

    @MainActor
    func testStartupBlocksActionsUntilActivationAndStopClearsState() {
        let model = EndpointWindowModel(socketPath: "/tmp/rai-endpoint-startup-test-\(UUID().uuidString).sock")
        let generation = model.generation
        model.start()
        XCTAssertTrue(model.busy)
        XCTAssertFalse(model.acceptsInput)
        model.perform("workspace.create", params: ["focus": .bool(true)])
        XCTAssertNil(model.error)
        model.stop()
        XCTAssertFalse(model.busy)
        XCTAssertNotEqual(model.generation, generation)
        XCTAssertNil(model.surface)
        XCTAssertTrue(model.methods.isEmpty)
    }
}

private final class TextRecorder: TerminalViewDelegate {
    var bytes: [UInt8] = []
    func send(source: TerminalView, data: ArraySlice<UInt8>) { bytes.append(contentsOf: data) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
