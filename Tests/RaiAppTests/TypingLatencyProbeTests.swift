import AppKit
import SwiftTerm
import XCTest

@testable import RaiApp

@MainActor
final class TypingLatencyProbeTests: XCTestCase {
    func testTypingThroughTheProductionPTYAndView() async throws {
        guard ProcessInfo.processInfo.environment["RAI_TYPING_LATENCY_PROBE"] == "1" else {
            throw XCTSkip("Set RAI_TYPING_LATENCY_PROBE=1 to run the typing benchmark.")
        }
        _ = NSApplication.shared
        for (name, padding, streaming) in [
            ("small-echo", 0, false),
            ("large-echo", 256, false),
            ("streaming", 256, true),
        ] {
            try await measure(name: name, padding: padding, streaming: streaming)
        }
    }

    private func measure(name: String, padding: Int, streaming: Bool) async throws {
        let frame = NSRect(x: 0, y: 0, width: 960, height: 600)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let view = FocusAwareTerminalView(frame: frame)
        let display = ProbeDelegate()
        display.view = view
        view.terminalDelegate = display
        window.contentView = view
        window.makeFirstResponder(view)
        view.notifyUpdateChanges = true
        view.configurePredictiveEcho(for: nil)
        defer {
            display.onDisplay = nil
            view.terminate()
            window.contentView = nil
        }

        // This subprocess belongs only to this test. It never connects to
        // Herdr or sends input to an existing user pane.
        let script = """
        import os, sys, threading, time, tty
        tty.setraw(0)
        padding = b'\\x1b[0m' * int(sys.argv[1])
        def output():
            counter = 0
            while True:
                frame = b'\\x1b[0m' * 256 + b'\\x1b[3;1Hprogress ' + str(counter).encode()
                os.write(1, frame)
                counter += 1
                time.sleep(0.005)
        if sys.argv[2] == '1':
            threading.Thread(target=output, daemon=True).start()
        os.write(1, b'\\x1b[H#')
        while True:
            value = os.read(0, 1)
            if not value: break
            os.write(1, padding + b'\\x1b[H' + value)
        """
        view.startProcess(
            executable: "/usr/bin/python3",
            args: ["-c", script, String(padding), streaming ? "1" : "0"],
            rawInput: true
        )
        for _ in 0..<300 {
            if view.getTerminal().getCharData(col: 0, row: 0)?.getCharacter() == "#" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(view.getTerminal().getCharData(col: 0, row: 0)?.getCharacter(), "#")
        var samples: [Double] = []
        for index in 0..<70 {
            let character = String(Character(UnicodeScalar(0x61 + index % 26)!))
            let updated = expectation(description: "display contains input \(index)")
            var elapsed: Double?
            let start = DispatchTime.now().uptimeNanoseconds
            display.onDisplay = { [weak view, weak display] in
                guard let view,
                      view.getTerminal().getCharData(col: 0, row: 0)?.getCharacter() == Character(character)
                else { return }
                elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                display?.onDisplay = nil
                updated.fulfill()
            }
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: character, charactersIgnoringModifiers: character,
                isARepeat: false, keyCode: 0
            ))
            if !view.handleInterceptedKey(event) { view.keyDown(with: event) }
            await fulfillment(of: [updated], timeout: 2)
            if index >= 10 { samples.append(try XCTUnwrap(elapsed)) }
            try await Task.sleep(for: .milliseconds(50))
        }
        samples.sort()
        print(String(
            format: "rai-pty-display-update scenario=%@ n=%d median=%.3fms p90=%.3fms max=%.3fms",
            name, samples.count, samples[samples.count / 2],
            samples[Int(ceil(Double(samples.count) * 0.9)) - 1], samples.last!
        ))
    }

    @MainActor
    private final class ProbeDelegate: NSObject, @preconcurrency TerminalViewDelegate {
        weak var view: FocusAwareTerminalView?
        var onDisplay: (() -> Void)?

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
            view?.rangeChanged(source: source, startY: startY, endY: endY)
            onDisplay?()
        }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            view?.sizeChanged(source: source, newCols: newCols, newRows: newRows)
        }
        func setTerminalTitle(source: TerminalView, title: String) {
            view?.setTerminalTitle(source: source, title: title)
        }
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            view?.hostCurrentDirectoryUpdate(source: source, directory: directory)
        }
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            view?.send(source: source, data: data)
        }
        func scrolled(source: TerminalView, position: Double) {
            view?.scrolled(source: source, position: position)
        }
    }
}
