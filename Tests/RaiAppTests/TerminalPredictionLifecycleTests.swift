import AppKit
import XCTest

@testable import RaiApp

@MainActor
final class TerminalPredictionLifecycleTests: XCTestCase {
    private func makeKeyEvent(for window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "x",
                charactersIgnoringModifiers: "x",
                isARepeat: false,
                keyCode: 7
            )
        )
    }

    func testApplicationResignActiveClearsPendingPrediction() throws {
        let app = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let view = FocusAwareTerminalView(frame: window.contentView!.bounds)
        view.enablePredictiveEcho(for: .local)
        window.contentView?.addSubview(view)

        let event = try makeKeyEvent(for: window)
        XCTAssertFalse(view.handleInterceptedKey(event))
        XCTAssertEqual(view.pendingPredictionCountForTesting, 1)

        NotificationCenter.default.post(
            name: NSApplication.didResignActiveNotification,
            object: app
        )

        XCTAssertEqual(view.pendingPredictionCountForTesting, 0)
    }

    func testWindowAndResponderFocusLossClearPendingPrediction() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let view = FocusAwareTerminalView(frame: window.contentView!.bounds)
        view.enablePredictiveEcho(for: .local)
        window.contentView?.addSubview(view)
        XCTAssertTrue(window.makeFirstResponder(view))
        let event = try makeKeyEvent(for: window)

        XCTAssertFalse(view.handleInterceptedKey(event))
        XCTAssertEqual(view.pendingPredictionCountForTesting, 1)
        NotificationCenter.default.post(
            name: NSWindow.didResignKeyNotification,
            object: window
        )
        XCTAssertEqual(view.pendingPredictionCountForTesting, 0)

        XCTAssertTrue(window.makeFirstResponder(view))
        XCTAssertFalse(view.handleInterceptedKey(event))
        XCTAssertEqual(view.pendingPredictionCountForTesting, 1)
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        window.contentView?.addSubview(textField)
        XCTAssertTrue(window.makeFirstResponder(textField))
        XCTAssertTrue(window.firstResponder !== view)
        XCTAssertEqual(view.pendingPredictionCountForTesting, 0)
    }
}
