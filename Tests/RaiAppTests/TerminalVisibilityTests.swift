import AppKit
import SwiftTerm
import XCTest

@testable import RaiApp

@MainActor
final class TerminalVisibilityTests: XCTestCase {
    private var directory: URL!
    private var executable: URL!
    private var pools: [TerminalPool] = []
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executable = directory.appendingPathComponent("attach")
        // Exercise a real PTY without connecting to any Herdr session.
        try "#!/bin/sh\nexec /bin/cat\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    override func tearDownWithError() throws {
        pools.forEach { $0.removeAll() }
        windows.forEach { $0.contentView = nil }
        pools.removeAll()
        windows.removeAll()
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    private func pool() -> TerminalPool {
        let pool = TerminalPool(socketPath: "/nonexistent/rai-visibility.sock", attachExecutable: executable.path)
        pools.append(pool)
        return pool
    }

    private func host() -> NSView {
        let frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSView(frame: frame)
        window.contentView = host
        windows.append(window)
        return host
    }

    private func show(_ view: FocusAwareTerminalView, in host: NSView) {
        view.frame = host.bounds
        host.addSubview(view)
        host.layoutSubtreeIfNeeded()
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("terminal lifecycle condition did not complete", file: file, line: line)
    }

    func testCachedViewWithoutWindowNeverLaunches() async throws {
        let view = try XCTUnwrap(pool().view(for: "term-hidden"))
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(view.process)
    }

    func testHiddenAncestorPreventsFirstAttachAndUnhideStartsIt() async throws {
        let view = try XCTUnwrap(pool().view(for: "term-hidden-parent"))
        let host = host()
        host.isHidden = true
        show(view, in: host)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(view.process)

        host.isHidden = false
        try await waitUntil { view.process?.running == true }
    }

    func testRemovalSuspendsClientAndResumeKeepsViewScrollbackAndInput() async throws {
        let pool = pool()
        let view = try XCTUnwrap(pool.view(for: "term-resume"))
        let host = host()
        show(view, in: host)
        try await waitUntil { view.process?.running == true }
        let originalProcess = try XCTUnwrap(view.process)
        view.feed(text: (0..<100).map { "cached row \($0)\r\n" }.joined())
        let savedBuffer = view.getTerminal().getBufferAsData()

        view.removeFromSuperview()
        try await waitUntil { view.process == nil }
        XCTAssertFalse(originalProcess.running)
        try await waitUntil { kill(originalProcess.shellPid, 0) == -1 && errno == ESRCH }
        XCTAssertTrue(pool.view(for: "term-resume") === view)
        XCTAssertEqual(view.getTerminal().getBufferAsData(), savedBuffer)

        show(view, in: host)
        XCTAssertEqual(view.getTerminal().getBufferAsData(), savedBuffer)
        // A cached grid can accept input immediately. Waiting for another
        // resize or a fallback timer would drop the first keys after a switch.
        view.send(txt: "input after resume\n")
        try await waitUntil {
            String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self).contains("input after resume")
        }
        XCTAssertFalse(view.process === originalProcess)
    }

    func testBriefContainerTransferKeepsTheExistingClient() async throws {
        let view = try XCTUnwrap(pool().view(for: "term-transfer"))
        let host = host()
        let outgoing = TerminalContainerView(frame: host.bounds)
        host.addSubview(outgoing)
        outgoing.install(view)
        host.layoutSubtreeIfNeeded()
        try await waitUntil { view.process?.running == true }
        let process = try XCTUnwrap(view.process)

        outgoing.detach()
        try await Task.sleep(for: .milliseconds(100))
        let incoming = TerminalContainerView(frame: host.bounds)
        host.addSubview(incoming)
        incoming.install(view)
        outgoing.install(view)
        outgoing.detach()
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(1_200))

        XCTAssertTrue(incoming.hostedTerminalView === view)
        XCTAssertTrue(view.process === process)
        XCTAssertTrue(process.running)
    }

    func testImmediateControlKeysSurviveReconnectBeforeClientSetup() async throws {
        // Herdr completes its socket handshake before it enables raw input.
        // Delay that setup and report the exact control bytes received.
        try "#!/bin/sh\n/bin/sleep 0.25\n/bin/stty raw -echo\nexec /usr/bin/od -An -v -tx1 -N 5\n"
            .write(to: executable, atomically: false, encoding: .utf8)
        let view = try XCTUnwrap(pool().view(for: "term-control-keys"))
        let host = host()
        show(view, in: host)
        try await waitUntil { view.process?.running == true }
        view.removeFromSuperview()
        try await waitUntil { view.process == nil }

        show(view, in: host)
        let controls: [UInt8] = [0x03, 0x7f, 0x16, 0x41, 0x0d]
        view.send(source: view, data: controls[...])
        try await waitUntil {
            String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self)
                .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                .contains("03 7f 16 41 0d")
        }
    }

    func testHidingAncestorSuspendsAndUnhidingResumesClient() async throws {
        let view = try XCTUnwrap(pool().view(for: "term-hide"))
        let host = host()
        show(view, in: host)
        try await waitUntil { view.process?.running == true }
        let process = try XCTUnwrap(view.process)

        host.isHidden = true
        try await waitUntil { view.process == nil }
        XCTAssertFalse(process.running)
        host.isHidden = false
        try await waitUntil { view.process?.running == true }
        XCTAssertFalse(view.process === process)
    }

    func testHideCancelsLaunchBeforeFirstLayout() async throws {
        let view = try XCTUnwrap(pool().view(for: "term-no-layout"))
        let host = host()
        view.frame = host.bounds
        host.addSubview(view)
        // No resize occurs after entering the window, so the fallback is pending.
        XCTAssertNil(view.process)
        view.removeFromSuperview()
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(view.process)
    }

    func testHiddenViewCancelsRetryWithoutClearingScrollback() async throws {
        let view = try XCTUnwrap(pool().view(for: "term-retry-hidden"))
        let host = host()
        show(view, in: host)
        try await waitUntil { view.process?.running == true }
        let process = try XCTUnwrap(view.process)
        view.feed(text: "keep this output")
        let savedBuffer = view.getTerminal().getBufferAsData()
        XCTAssertEqual(kill(process.shellPid, SIGTERM), 0)
        try await waitUntil { !process.running }
        // Allow the main-queue exit callback to schedule its delayed retry.
        try await Task.sleep(for: .milliseconds(50))
        view.removeFromSuperview()
        try await Task.sleep(for: .milliseconds(600))

        XCTAssertNil(view.process)
        XCTAssertEqual(view.getTerminal().getBufferAsData(), savedBuffer)
        show(view, in: host)
        try await waitUntil { view.process?.running == true }
        XCTAssertEqual(view.getTerminal().getBufferAsData(), savedBuffer)
    }

    func testVisibleExitRetriesButEvictionCancelsFurtherRetries() async throws {
        let pool = pool()
        let view = try XCTUnwrap(pool.view(for: "term-retry-evict"))
        let host = host()
        show(view, in: host)
        try await waitUntil { view.process?.running == true }
        let first = try XCTUnwrap(view.process)
        XCTAssertEqual(kill(first.shellPid, SIGTERM), 0)
        try await waitUntil { view.process !== first && view.process?.running == true }

        let second = try XCTUnwrap(view.process)
        XCTAssertEqual(kill(second.shellPid, SIGTERM), 0)
        try await waitUntil { !second.running }
        try await Task.sleep(for: .milliseconds(50))
        pool.retain(terminalIDs: [])
        show(view, in: host)
        try await Task.sleep(for: .milliseconds(1_000))

        XCTAssertNil(view.process)
        XCTAssertNil(pool.view(for: "term-retry-evict"))
    }
}
