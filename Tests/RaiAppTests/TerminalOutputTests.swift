import AppKit
import SwiftTerm
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
        let displayed = delegate.displays
        let bytes = Array(("\u{1B}[?2026h" + String(repeating: "\u{1B}[Hafter", count: 3_000)).utf8)
        view.feed(byteArray: bytes[...])
        try await Task.sleep(for: .milliseconds(100))
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
            observe: { observed.append($0) },
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
        DispatchQueue.global(qos: .userInitiated).sync {
            bookkeeping.append([1, 2, 3][...])
            bookkeeping.append([4, 5][...])
        }
        try await waitUntil { batches.count == 1 }
        XCTAssertEqual(batches.map(\.bytes), [[1, 2, 3, 4, 5]])
        XCTAssertEqual(batches.map(\.overflowed), [false])

        bookkeeping.append(Array(repeating: 9, count: 9)[...])
        bookkeeping.append([1][...])
        try await waitUntil { batches.count == 2 }
        XCTAssertEqual(batches.count, 2)
        XCTAssertTrue(batches[1].overflowed, "a burst above the limit is not replayed")
        XCTAssertTrue(batches[1].bytes.isEmpty)

        bookkeeping.append([7][...])
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
            observer(echo[...])
        }
        try await waitUntil { view.pendingPredictionCountForTesting == 0 }
        XCTAssertEqual(view.pendingPredictionCountForTesting, 0)
        XCTAssertEqual(view.cursorPosition.col, 1)
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
