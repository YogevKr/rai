import AppKit
import XCTest

@testable import RaiApp
@testable import RaiCore

@MainActor
final class TerminalPredictionLifecycleTests: XCTestCase {
    private final class TestUptime {
        var nanoseconds: UInt64 = 1_000_000_000
    }

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

    func testVisiblePredictionSchedulesMonotonicExpiryRedraw() {
        _ = NSApplication.shared
        let uptime = TestUptime()
        let engine = PredictiveEchoEngine(
            displayLatencyThreshold: PredictiveEchoEngine.HerdLocation.local
                .displayLatencyThreshold,
            monotonicNow: { uptime.nanoseconds }
        )
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        engine.noteKey(
            .printable("a"),
            cursor: (x: 0, y: 0),
            columns: 80,
            terminalMode: .plain,
            now: start
        )
        uptime.nanoseconds += 20_000_000
        engine.reconcile(
            cursor: (x: 1, y: 0),
            terminalMode: .plain,
            outputBytes: [UInt8(ascii: "a")][...],
            readCell: { column, _ in column == 0 ? "a" : nil },
            now: start.addingTimeInterval(0.020)
        )
        uptime.nanoseconds += 1_000_000
        engine.noteKey(
            .printable("b"),
            cursor: (x: 0, y: 0),
            columns: 80,
            terminalMode: .plain,
            now: start.addingTimeInterval(0.021)
        )
        let view = FocusAwareTerminalView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 200)
        )
        let expectedDeadline = engine.displayExpiryDeadlineUptimeNanoseconds
        XCTAssertNotNil(expectedDeadline)

        view.showPredictiveEchoForTesting(engine)

        XCTAssertEqual(
            view.predictionExpiryDeadlineForTesting,
            expectedDeadline
        )
        view.resetPredictions()
    }
}
