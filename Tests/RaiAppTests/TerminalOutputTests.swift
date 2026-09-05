import AppKit
import SwiftTerm
import XCTest
@testable import RaiApp

@MainActor
final class TerminalOutputTests: XCTestCase {
    private func view() -> FocusAwareTerminalView {
        _ = NSApplication.shared
        let view = FocusAwareTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
        view.getTerminal().changeScrollback(2_000)
        return view
    }

    func testLargeBacklogYieldsBeforeItFinishes() async {
        let view = view()
        defer { view.terminate() }
        let payload = Array(String(repeating: "\u{1B}[Houtput", count: 100_000).utf8)
        let finished = expectation(description: "all output parsed")
        view.dataReceived(slice: payload[...]) { finished.fulfill() }
        let event = expectation(description: "main queue runs during parsing")
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(5)) {
            XCTAssertGreaterThan(view.pendingOutputBytesForTesting, 0)
            XCTAssertLessThan(view.pendingOutputBytesForTesting, payload.count)
            event.fulfill()
        }
        await fulfillment(of: [event, finished], timeout: 5, enforceOrder: true)
        XCTAssertEqual(view.pendingOutputBytesForTesting, 0)
    }

    func testChunkedUnicodeAndEscapeSequencesMatchAnUninterruptedParse() async {
        let view = view()
        defer { view.terminate() }
        let reference = self.view()
        let bytes = Array((0..<800).map {
            "\u{1B}[3\($0 % 8)m\($0): שלום 🙂 e\u{301}\u{1B}[0m\r\n"
        }.joined().utf8)
        reference.getTerminal().feed(buffer: bytes[...])
        let finished = expectation(description: "all reads acknowledged")
        finished.expectedFulfillmentCount = 3
        var acknowledgements: [Int] = []
        let cuts = [0, 16_385, 16_392, bytes.count]
        for index in 0..<3 {
            view.dataReceived(slice: bytes[cuts[index]..<cuts[index + 1]]) {
                acknowledgements.append(index)
                finished.fulfill()
            }
        }
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(acknowledgements, [0, 1, 2])
        XCTAssertEqual(view.getTerminal().getBufferAsData(), reference.getTerminal().getBufferAsData())
        XCTAssertEqual(view.getTerminal().getCursorLocation().x, reference.getTerminal().getCursorLocation().x)
        XCTAssertEqual(view.getTerminal().getCursorLocation().y, reference.getTerminal().getCursorLocation().y)
        for row in 0..<view.getTerminal().rows {
            XCTAssertEqual(view.getTerminal().getCharData(col: 0, row: row)?.attribute,
                           reference.getTerminal().getCharData(col: 0, row: row)?.attribute)
        }
    }

    func testSynchronizedOutputStaysHiddenUntilItsClosingMarker() async throws {
        let view = view()
        defer { view.terminate() }
        let delegate = DisplayCounter()
        view.terminalDelegate = delegate
        view.notifyUpdateChanges = true
        view.feed(text: "before")
        try await Task.sleep(for: .milliseconds(50))
        let displayed = delegate.displays
        let bytes = Array(("\u{1B}[?2026h" + String(repeating: "\u{1B}[Hafter", count: 3_000)).utf8)
        let parsed = expectation(description: "open synchronized frame parsed")
        view.dataReceived(slice: bytes[...]) { parsed.fulfill() }
        await fulfillment(of: [parsed], timeout: 3)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(view.getTerminal().synchronizedOutputActive)
        XCTAssertEqual(delegate.displays, displayed)
        view.dataReceived(slice: Array("\u{1B}[?2026l".utf8)[...])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(view.getTerminal().synchronizedOutputActive)
        XCTAssertGreaterThan(delegate.displays, displayed)
    }

    func testTerminateReleasesPendingReadsAndDiscardsOldOutput() async throws {
        let view = view()
        var completions = 0
        view.dataReceived(slice: Array(repeating: UInt8(ascii: "x"), count: 100_000)[...]) {
            completions += 1
        }
        view.terminate()
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(view.pendingOutputBytesForTesting, 0)
        view.dataReceived(slice: Array("new session".utf8)[...])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(completions, 1)
        let text = String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("new session"))
        XCTAssertFalse(text.contains("xxx"))
    }

    func testTransportWaitsForConsumptionAndStopReleasesTheWait() async {
        let first = expectation(description: "first read delivered")
        let released = expectation(description: "worker released")
        var completeFirst: (() -> Void)?
        var deliveries = 0
        let driver = TerminalProcessOutput(windowSize: winsize(), receive: { _, complete in
            deliveries += 1
            completeFirst = complete
            first.fulfill()
        }, exited: { _ in })
        DispatchQueue.global(qos: .userInitiated).async {
            driver.dataReceived(slice: [1, 2, 3])
            driver.dataReceived(slice: [4, 5, 6])
            released.fulfill()
        }
        await fulfillment(of: [first], timeout: 2)
        XCTAssertEqual(deliveries, 1)
        driver.stop()
        await fulfillment(of: [released], timeout: 2)
        completeFirst?()
        XCTAssertEqual(deliveries, 1)
    }

    func testTransportReleasesTheNextReadOnlyAfterAcknowledgement() async {
        let first = expectation(description: "first read delivered")
        let second = expectation(description: "second read delivered")
        var completion: (() -> Void)?
        var deliveries = 0
        let driver = TerminalProcessOutput(windowSize: winsize(), receive: { _, complete in
            deliveries += 1
            if deliveries == 1 {
                completion = complete
                first.fulfill()
            } else {
                complete()
                second.fulfill()
            }
        }, exited: { _ in })
        defer { driver.stop() }
        DispatchQueue.global(qos: .userInitiated).async {
            driver.dataReceived(slice: [1])
            driver.dataReceived(slice: [2])
        }
        await fulfillment(of: [first], timeout: 2)
        XCTAssertEqual(deliveries, 1)
        completion?()
        await fulfillment(of: [second], timeout: 2)
        XCTAssertEqual(deliveries, 2)
    }

    func testRealPTYAcceptsKeysWhileOutputIsBackpressured() async throws {
        _ = NSApplication.shared
        let view = HeldOutputView(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
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
        for _ in 0..<300 where view.pendingOutputBytesForTesting == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertGreaterThan(view.pendingOutputBytesForTesting, 0)
        XCTAssertLessThanOrEqual(view.pendingOutputBytesForTesting, 128 * 1024)
        view.send(txt: "x")
        for _ in 0..<300 where !FileManager.default.fileExists(atPath: result.path) {
            try await Task.sleep(for: .milliseconds(5))
            XCTAssertLessThanOrEqual(view.pendingOutputBytesForTesting, 128 * 1024)
        }
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
        for _ in 0..<300 where !FileManager.default.fileExists(atPath: ready.path) {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        view.resize(cols: 101, rows: 31)
        view.send(txt: "x")
        for _ in 0..<300 where !FileManager.default.fileExists(atPath: result.path) {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(try String(contentsOf: result), "31,101")
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

    /// Hold a real transport read until the test sends a key. This makes
    /// backpressure deterministic even when the kernel returns tiny reads.
    private final class HeldOutputView: TerminalProcessView {
        var pendingOutputBytesForTesting = 0
        private var complete: (() -> Void)?
        override func dataReceived(slice: ArraySlice<UInt8>, completion: @escaping () -> Void) {
            pendingOutputBytesForTesting = slice.count
            complete = completion
        }
        override func discardPendingOutput() {
            pendingOutputBytesForTesting = 0
            let complete = complete
            self.complete = nil
            complete?()
        }
    }
}
