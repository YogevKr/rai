import AppKit
import RaiCore
@testable import SwiftTerm
import XCTest
@testable import RaiApp

/// SwiftTerm 2 parses process output on its pipeline thread and paces its
/// own frames. These tests cover what rai still owns: the driver that feeds
/// the view off-main, the coalesced main hop for prediction bookkeeping, and
/// the PTY session lifecycle.
@MainActor
final class TerminalOutputTests: XCTestCase {
    private func view() -> FocusAwareTerminalView {
        _ = NSApplication.shared
        return FocusAwareTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
    }

    private func text(of view: TerminalView) -> String {
        String(decoding: view.getBufferAsData(), as: UTF8.self)
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// SwiftTerm binds its display link when the view enters a window and
    /// reads the window's occlusion state then. XCTest pumps no app events,
    /// so a later occlusion change never arrives: show the window first.
    private func onScreenWindow(for view: TerminalView) -> NSWindow {
        let window = NSWindow(
            contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.orderFrontRegardless()
        window.contentView = view
        view.suspendsRenderingWhenNotVisible = false
        return window
    }

    func testChunkedUnicodeAndEscapeSequencesMatchAnUninterruptedParse() async {
        let view = view()
        let reference = self.view()
        let bytes = Array((0..<800).map {
            "\u{1B}[3\($0 % 8)m\($0): שלום 🙂 e\u{301}\u{1B}[0m\r\n"
        }.joined().utf8)
        reference.feed(byteArray: bytes[...])
        // Cut inside a multi-byte scalar and inside an escape sequence, the
        // way the pipeline's 64 KiB batches can.
        let cuts = [0, 16_385, 16_392, bytes.count]
        let sender = view.feedSender
        let fed = expectation(description: "chunks fed from a background thread")
        DispatchQueue.global(qos: .userInitiated).async {
            for index in 0..<3 {
                sender.feed(byteArray: bytes[cuts[index]..<cuts[index + 1]])
            }
            fed.fulfill()
        }
        await fulfillment(of: [fed], timeout: 5)
        XCTAssertEqual(view.getBufferAsData(), reference.getBufferAsData())
        XCTAssertEqual(view.cursorPosition.col, reference.cursorPosition.col)
        XCTAssertEqual(view.cursorPosition.row, reference.cursorPosition.row)
    }

    func testOutputFeedingDoesNotBlockTheMainRunLoop() async throws {
        let view = view()
        let line = Array("\u{1B}[32moutput \u{1B}[0mline\r\n".utf8)
        let payload = Array((0..<(4 * 1024 * 1024 / line.count + 1)).flatMap { _ in line })
        XCTAssertGreaterThanOrEqual(payload.count, 4 * 1024 * 1024)
        let ticks = RunLoopTicks()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.001, repeats: true) { _ in
            MainActor.assumeIsolated { ticks.tick() }
        }
        defer { timer.invalidate() }
        let sender = view.feedSender
        let fed = expectation(description: "4 MB fed from a background thread")
        DispatchQueue.global(qos: .userInitiated).async {
            var offset = 0
            while offset < payload.count {
                let end = min(offset + 64 * 1024, payload.count)
                sender.feed(byteArray: payload[offset..<end])
                offset = end
            }
            fed.fulfill()
        }
        let started = DispatchTime.now().uptimeNanoseconds
        await fulfillment(of: [fed], timeout: 60)
        let feedMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        print(String(format: "main-loop-under-feed ticks=%d maxGap=%.1fms feed=%.1fms", ticks.count, ticks.maxGapMilliseconds, feedMilliseconds))
        XCTAssertGreaterThan(ticks.count, 20, "the main run loop kept servicing its timer")
        XCTAssertLessThan(ticks.maxGapMilliseconds, 250, "no main-thread stall while parsing")
        XCTAssertTrue(text(of: view).contains("output line"))
    }

    func testSynchronizedOutputStaysHiddenUntilItsClosingMarker() async throws {
        let view = view()
        let window = onScreenWindow(for: view)
        defer { window.contentView = nil; window.orderOut(nil) }
        let delegate = DisplayCounter()
        view.terminalDelegate = delegate
        view.notifyUpdateChanges = true
        view.feed(text: "before")
        try await waitUntil { delegate.displays > 0 }
        XCTAssertGreaterThan(delegate.displays, 0, "frames arrive while the window is visible")
        // A frame without content changes still reports the cursor row, so
        // wait until the display is quiet before opening the batch.
        var displayed = delegate.displays
        var quietChecks = 0
        while quietChecks < 8 {
            try await Task.sleep(for: .milliseconds(20))
            if delegate.displays == displayed { quietChecks += 1 } else {
                displayed = delegate.displays
                quietChecks = 0
            }
        }
        let bytes = Array(("\u{1B}[?2026h" + String(repeating: "\u{1B}[Hafter", count: 3_000)).utf8)
        view.feed(byteArray: bytes[...])
        try await waitUntil { view.terminalModeFlags().synchronizedOutputActive }
        XCTAssertTrue(view.terminalModeFlags().synchronizedOutputActive)
        // Stay well under SwiftTerm's one-second synchronized-output watchdog.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(view.terminalModeFlags().synchronizedOutputActive)
        XCTAssertEqual(delegate.displays, displayed, "no frame while the batch is open")
        view.feed(text: "\u{1B}[?2026l")
        try await waitUntil { delegate.displays > displayed }
        XCTAssertFalse(view.terminalModeFlags().synchronizedOutputActive)
        XCTAssertGreaterThan(delegate.displays, displayed)
    }

    func testStoppedDriverNeverFeedsAStaleView() async throws {
        let view = view()
        let observed = ObservedOutput()
        let exits = expectation(description: "exit delivered")
        exits.isInverted = true
        let driver = TerminalProcessOutput(
            windowSize: winsize(),
            feed: view.feedSender,
            cursor: TerminalCursorProbe(view: view),
            observe: { bytes, _ in observed.append(bytes) },
            exited: { _ in exits.fulfill() }
        )
        driver.dataReceived(slice: Array("live".utf8)[...])
        XCTAssertTrue(text(of: view).hasPrefix("live"))
        driver.stop()
        driver.dataReceived(slice: Array("stale".utf8)[...])
        driver.processTerminated(LocalProcess(delegate: driver), exitCode: 0)
        await fulfillment(of: [exits], timeout: 0.1)
        XCTAssertFalse(text(of: view).contains("stale"))
        XCTAssertEqual(observed.bytes, Array("live".utf8))
    }

    func testOutputBookkeepingCoalescesChunksAndBoundsBursts() async throws {
        var batches: [TerminalOutputBookkeeping.Batch] = []
        var bookkeeping: TerminalOutputBookkeeping!
        bookkeeping = TerminalOutputBookkeeping(limit: 8) {
            batches.append(bookkeeping.take())
        }
        let first = Position(col: 3, row: 0)
        let second = Position(col: 5, row: 0)
        DispatchQueue.global(qos: .userInitiated).sync {
            bookkeeping.append([1, 2, 3][...], cursor: first)
            bookkeeping.append([4, 5][...], cursor: second)
        }
        try await waitUntil { batches.count == 1 }
        XCTAssertEqual(batches.map(\.bytes), [[1, 2, 3, 4, 5]])
        XCTAssertEqual(batches.first?.chunks, [
            .init(bytes: [1, 2, 3], cursor: first), .init(bytes: [4, 5], cursor: second),
        ], "each chunk keeps the cursor recorded after its own parse")
        XCTAssertEqual(batches.map(\.overflowed), [false])
        XCTAssertFalse(bookkeeping.framePresented(since: batches[0]))
        bookkeeping.noteFramePresented()
        XCTAssertTrue(bookkeeping.framePresented(since: batches[0]))

        bookkeeping.append(Array(repeating: 9, count: 9)[...], cursor: first)
        bookkeeping.append([1][...], cursor: first)
        try await waitUntil { batches.count == 2 }
        XCTAssertEqual(batches.count, 2)
        XCTAssertTrue(batches[1].overflowed, "a burst above the limit is not replayed")
        XCTAssertTrue(batches[1].bytes.isEmpty)
        XCTAssertFalse(bookkeeping.framePresented(since: batches[1]),
                       "the generation is recorded at the last append")

        bookkeeping.append([7][...], cursor: first)
        bookkeeping.discard()
        try await waitUntil { batches.count == 3 }
        XCTAssertEqual(batches.count, 3)
        XCTAssertTrue(batches[2].isEmpty, "discarded output does not reach the main hop")
    }

    func testOutputFedOffMainConfirmsPredictionsOnTheMainHop() async throws {
        let view = view()
        let window = onScreenWindow(for: view)
        window.makeFirstResponder(view)
        defer { window.contentView = nil; window.orderOut(nil) }
        view.configurePredictiveEcho(for: .local)
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7
        ))
        _ = view.handleInterceptedKey(event)
        XCTAssertEqual(view.pendingPredictionCountForTesting, 1)

        // The driver feeds the parser, then hands the chunk to the observer.
        let sender = view.feedSender
        let observer = try XCTUnwrap(view.outputObserver)
        let echo = Array("x".utf8)
        DispatchQueue.global(qos: .userInitiated).async {
            sender.feed(byteArray: echo[...])
            observer(echo[...], view.cursorPosition)
        }
        try await waitUntil { view.pendingPredictionCountForTesting == 0 }
        XCTAssertEqual(view.pendingPredictionCountForTesting, 0)
        XCTAssertEqual(view.cursorPosition.col, 1)
    }

    /// A read that passed the stopped check must finish before `stop()`
    /// returns. Otherwise `terminate()` resets the terminal while the read
    /// still waits for the terminal lock, and the stale bytes land in the
    /// cleared buffer or in the next session.
    ///
    /// The terminal lock cannot be held from a worker here: SwiftTerm's own
    /// main-thread work takes it during the run-loop wait. The driver is
    /// blocked inside its critical section instead, after the feed and
    /// before `dataReceived` returns.
    func testStopWaitsForAnInFlightFeedBeforeItReturns() async throws {
        let view = view()
        let inFlight = expectation(description: "read in flight")
        let releaseRead = DispatchSemaphore(value: 0)
        let driver = TerminalProcessOutput(
            windowSize: winsize(),
            feed: view.feedSender,
            cursor: TerminalCursorProbe(view: view),
            observe: { _, _ in
                inFlight.fulfill()
                releaseRead.wait()
            },
            exited: { _ in }
        )
        let workers = DispatchQueue(label: "rai.race", attributes: .concurrent)
        workers.async {
            driver.dataReceived(slice: Array("stale".utf8)[...])
        }
        await fulfillment(of: [inFlight], timeout: 2)
        let stoppedEarly = expectation(description: "stop returned while a read was in flight")
        stoppedEarly.isInverted = true
        let stopped = expectation(description: "stop returned")
        workers.async {
            driver.stop()
            stoppedEarly.fulfill()
            stopped.fulfill()
        }
        await fulfillment(of: [stoppedEarly], timeout: 0.3)
        releaseRead.signal()
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertTrue(text(of: view).hasPrefix("stale"), "the in-flight read completed before stop returned")
        // Everything that follows stop() is ordered after the stale bytes.
        view.resetToInitialState()
        driver.dataReceived(slice: Array("late".utf8)[...])
        XCTAssertFalse(text(of: view).contains("stale"))
        XCTAssertFalse(text(of: view).contains("late"))
    }

    /// Builds a confident engine with "b" pending after "a" was echoed, so
    /// the overlay draws. The view's cursor ends at column 1.
    private func confidentEngine(in view: FocusAwareTerminalView, pending: String = "b") throws -> PredictiveEchoEngine {
        let engine = PredictiveEchoEngine(displayLatencyThreshold: 0)
        let typed = Date()
        engine.noteKey(.printable("a"), cursor: (x: 0, y: 0), columns: 80, terminalMode: .plain, now: typed)
        for character in pending {
            engine.noteKey(.printable(character), cursor: (x: 0, y: 0), columns: 80, terminalMode: .plain, now: typed)
        }
        view.feed(text: "a")
        engine.reconcile(
            cursor: (x: 1, y: 0), terminalMode: .plain,
            readCell: { column, row in column == 0 && row == 0 ? "a" : nil },
            now: typed.addingTimeInterval(0.05)
        )
        XCTAssertEqual(engine.displayGlyphs(), Array(pending))
        return engine
    }

    /// SwiftTerm reports `rangeChanged` before it moves the caret view, so
    /// the overlay must follow the cursor cell, not the caret's stale origin.
    func testOverlayFollowsTheCursorCellNotTheStaleCaret() async throws {
        let view = view()
        let window = onScreenWindow(for: view)
        window.makeFirstResponder(view)
        defer { window.contentView = nil; window.orderOut(nil) }
        let engine = try confidentEngine(in: view)
        view.showPredictiveEchoForTesting(engine)
        let cell = view.caretFrame.size
        XCTAssertGreaterThan(cell.width, 0)
        let overlay = try XCTUnwrap(view.predictionOverlayFrameForTesting)
        XCTAssertEqual(view.cursorPosition.col, 1)
        XCTAssertEqual(overlay.origin.x, cell.width, accuracy: 0.01, "one column right of the echoed glyph")
        XCTAssertEqual(overlay.origin.y, view.frame.height - cell.height, accuracy: 0.01)
        // Once a frame lands, the caret agrees with the overlay.
        try await waitUntil { abs(view.caretFrame.minX - cell.width) < 0.01 }
        XCTAssertEqual(view.caretFrame.minX, overlay.origin.x, accuracy: 0.01)
        XCTAssertEqual(
            FocusAwareTerminalView.overlayOrigin(
                cursor: Position(col: 7, row: 3), cellSize: CGSize(width: 10, height: 20), viewHeight: 200
            ),
            CGPoint(x: 70, y: 120)
        )
    }

    /// The frame that paints the confirming echo can land before the main
    /// hop runs. The hop must then update the overlay itself instead of
    /// waiting for a frame that already happened.
    func testConfirmingFrameBeforeTheMainHopStillRetractsTheOverlay() async throws {
        let view = view()
        let window = onScreenWindow(for: view)
        window.makeFirstResponder(view)
        defer { window.contentView = nil; window.orderOut(nil) }
        let engine = try confidentEngine(in: view)
        view.showPredictiveEchoForTesting(engine)
        XCTAssertNotNil(view.predictionOverlayFrameForTesting)
        let observer = try XCTUnwrap(view.outputObserver)
        let echo = Array("b".utf8)
        view.feed(byteArray: echo[...])
        observer(echo[...], view.cursorPosition)
        // The frame lands before the scheduled hop runs.
        view.noteFramePresentedForTesting()
        try await waitUntil { view.pendingPredictionCountForTesting == 0 }
        XCTAssertEqual(view.pendingPredictionCountForTesting, 0)
        XCTAssertFalse(view.predictionOverlayUpdatePendingForTesting, "no wait for a frame that already landed")
        XCTAssertNil(view.predictionOverlayFrameForTesting, "the confirmed glyph is no longer overlaid")
    }

    /// Two chunks can parse before one hop runs. Each chunk must reconcile
    /// against its own cursor, or the second chunk's cursor makes the first
    /// chunk confirm two glyphs for one byte and the burst is dropped.
    func testEachChunkReconcilesAgainstItsOwnCursor() async throws {
        let view = view()
        let window = onScreenWindow(for: view)
        window.makeFirstResponder(view)
        defer { window.contentView = nil; window.orderOut(nil) }
        let engine = try confidentEngine(in: view, pending: "bcd")
        view.showPredictiveEchoForTesting(engine)
        XCTAssertEqual(view.pendingPredictionCountForTesting, 3)
        let observer = try XCTUnwrap(view.outputObserver)
        // The pipeline thread parses "b" then "c" before the hop runs.
        DispatchQueue.global(qos: .userInitiated).sync {
            for echo in ["b", "c"] {
                view.feedSender.feed(byteArray: Array(echo.utf8)[...])
                observer(Array(echo.utf8)[...], view.cursorPosition)
            }
        }
        try await waitUntil { view.pendingPredictionCountForTesting == 1 }
        XCTAssertEqual(view.pendingPredictionCountForTesting, 1, "\"d\" stays predicted")
        XCTAssertEqual(engine.pending.map(\.character), ["d"])
        XCTAssertTrue(engine.echoConfirmedThisBurst)
    }

    /// Cells are read one at a time from the buffer, so a grapheme that
    /// Swift merges into one Character cannot shift the columns after it.
    func testPredictionCellReadsFollowBufferColumns() throws {
        let view = view()
        view.feed(text: "a\u{1F44D}\u{1F3FD}b")
        XCTAssertEqual(view.predictionCellForTesting(column: 0, row: 0), "a")
        let afterGlyph = view.cursorPosition.col - 1
        XCTAssertEqual(view.predictionCellForTesting(column: afterGlyph, row: 0), "b")
        XCTAssertNil(view.predictionCellForTesting(column: afterGlyph + 1, row: 0), "an unwritten cell reads nil")
        view.feed(text: "\r\n\u{1B}[3Cz")
        XCTAssertEqual(view.predictionCellForTesting(column: 3, row: 1), "z")
        XCTAssertEqual(view.predictionCellForTesting(column: 1, row: 1), " ", "a blank cell before content reads as a space")
    }

    func testTerminateDiscardsOldOutputAndTheNextSessionStartsClean() async throws {
        let view = view()
        defer { view.terminate() }
        let script = """
        import os
        block = b'\\x1b[Hold' * 4096
        while True: os.write(1, block)
        """
        view.startProcess(executable: "/usr/bin/python3", args: ["-c", script])
        try await waitUntil { text(of: view).contains("old") }
        XCTAssertTrue(text(of: view).contains("old"))
        view.terminate()
        // A batch already inside the parser lands within SwiftTerm's drain.
        try await Task.sleep(for: .milliseconds(700))
        view.resetToInitialState()
        let cleared = view.getBufferAsData()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(view.getBufferAsData(), cleared, "a stopped driver feeds nothing")
        view.startProcess(executable: "/bin/sh", args: ["-c", "printf 'new session'; sleep 30"])
        try await waitUntil { text(of: view).hasPrefix("new session") }
        XCTAssertTrue(text(of: view).hasPrefix("new session"))
        XCTAssertFalse(text(of: view).contains("old"))
    }

    func testRealPTYAcceptsKeysWhileOutputFloods() async throws {
        let view = view()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = directory.appendingPathComponent("input.txt")
        defer {
            view.terminate()
            try? FileManager.default.removeItem(at: directory)
        }
        let script = """
        import os, sys, threading, tty
        tty.setraw(0)
        def output():
            block = b'\\x1b[Houtput' * 4096
            for _ in range(1000): os.write(1, block)
        threading.Thread(target=output, daemon=True).start()
        value = os.read(0, 1)
        with open(sys.argv[1], 'wb') as result: result.write(value)
        threading.Event().wait()
        """
        view.startProcess(executable: "/usr/bin/python3", args: ["-c", script, result.path])
        try await waitUntil { text(of: view).contains("output") }
        XCTAssertTrue(text(of: view).contains("output"))
        view.send(txt: "x")
        try await waitUntil { FileManager.default.fileExists(atPath: result.path) }
        XCTAssertEqual(try Data(contentsOf: result), Data("x".utf8))
    }

    func testRealPTYReceivesTheUpdatedGridSize() async throws {
        let view = view()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ready = directory.appendingPathComponent("ready")
        let result = directory.appendingPathComponent("size.txt")
        defer {
            view.terminate()
            try? FileManager.default.removeItem(at: directory)
        }
        let script = """
        import os, sys, tty, fcntl, termios, struct, threading
        tty.setraw(0)
        open(sys.argv[1], 'w').close()
        os.read(0, 1)
        size = struct.unpack('HHHH', fcntl.ioctl(0, termios.TIOCGWINSZ, b'\\0' * 8))
        with open(sys.argv[2], 'w') as result: result.write('%d,%d' % size[:2])
        threading.Event().wait()
        """
        view.startProcess(executable: "/usr/bin/python3", args: ["-c", script, ready.path, result.path])
        try await waitUntil { FileManager.default.fileExists(atPath: ready.path) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        view.resize(cols: 101, rows: 31)
        view.send(txt: "x")
        try await waitUntil { FileManager.default.fileExists(atPath: result.path) }
        XCTAssertEqual(try String(contentsOf: result, encoding: .utf8), "31,101")
    }

    private final class DisplayCounter: TerminalViewDelegate {
        var displays = 0
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func send(source: TerminalView, data: ArraySlice<UInt8>) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) { displays += 1 }
    }

    private final class ObservedOutput: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [UInt8] = []
        var bytes: [UInt8] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        func append(_ chunk: ArraySlice<UInt8>) {
            lock.lock()
            stored.append(contentsOf: chunk)
            lock.unlock()
        }
    }

    @MainActor
    private final class RunLoopTicks {
        private(set) var count = 0
        private var last: UInt64?
        private(set) var maxGapNanoseconds: UInt64 = 0
        var maxGapMilliseconds: Double { Double(maxGapNanoseconds) / 1_000_000 }
        func tick() {
            let now = DispatchTime.now().uptimeNanoseconds
            if let last { maxGapNanoseconds = max(maxGapNanoseconds, now - last) }
            last = now
            count += 1
        }
    }
}
