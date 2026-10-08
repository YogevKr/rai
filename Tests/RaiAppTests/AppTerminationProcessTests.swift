import Foundation
import XCTest

/// Real AppKit lifecycle tests run in an owned process. The fixture has no
/// Herdr connection, network listener, window, or access to user preferences.
final class AppTerminationProcessTests: XCTestCase {
    func testNativeQuitAndUpdateExitEvenWhenCleanupNeverCompletes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rai-quit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Probe.swift")
        try Self.probe.write(to: source, atomically: true, encoding: .utf8)
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let binary = root.appendingPathComponent("probe")
        let buildLog = root.appendingPathComponent("build.log")
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["swiftc", "-parse-as-library", "-o", binary.path,
            package.appendingPathComponent("Sources/RaiApp/AppTermination.swift").path, source.path]
        FileManager.default.createFile(atPath: buildLog.path, contents: nil)
        let output = try FileHandle(forWritingTo: buildLog)
        defer { try? output.close() }
        compiler.standardOutput = output
        compiler.standardError = output
        try compiler.run()
        compiler.waitUntilExit()
        let diagnostics = try String(contentsOf: buildLog)
        XCTAssertEqual(compiler.terminationStatus, 0, diagnostics)
        guard compiler.terminationStatus == 0 else { return }

        for mode in ["quit", "update", "update-stalled"] {
            let log = root.appendingPathComponent("\(mode).log")
            let process = Process()
            process.executableURL = binary
            process.arguments = [mode, log.path]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            let exited = !process.isRunning
            if !exited {
                // This exact child is the disposable fixture, never the user's Rai.
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            XCTAssertTrue(exited, "AppKit did not finish \(mode)")
            XCTAssertEqual(process.terminationStatus, 0, mode)
            let events = (try? String(contentsOf: log)) ?? ""
            XCTAssertTrue(events.contains("cleanup-started\n"), events)
            XCTAssertTrue(events.hasSuffix("will-terminate\n"), events)
            XCTAssertEqual(events.contains("cleanup-finished\n"), mode != "update-stalled", events)
        }
    }

    private static let probe = #"""
    import AppKit

    @MainActor
    final class Delegate: NSObject, NSApplicationDelegate {
        let coordinator = AppTerminationCoordinator(timeout: .milliseconds(250))
        var stalled: CheckedContinuation<Void, Never>?
        let mode = CommandLine.arguments[1]
        let log = URL(fileURLWithPath: CommandLine.arguments[2])

        func record(_ text: String) {
            let previous = (try? String(contentsOf: log)) ?? ""
            try! (previous + text + "\n").write(to: log, atomically: true, encoding: .utf8)
        }

        func applicationDidFinishLaunching(_ notification: Notification) {
            if mode == "quit" {
                RunLoop.main.perform { NSApp.terminate(nil) }
            } else {
                Task { @MainActor in AppTermination.schedule() }
            }
        }

        func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
            coordinator.request(shutdown: {
                self.record("cleanup-started")
                if self.mode == "update-stalled" {
                    await withCheckedContinuation { self.stalled = $0 }
                } else {
                    try? await Task.sleep(for: .milliseconds(30))
                    self.record("cleanup-finished")
                }
            }, reply: { sender.reply(toApplicationShouldTerminate: true) })
        }

        func applicationWillTerminate(_ notification: Notification) { record("will-terminate") }
    }

    @main
    struct Probe {
        @MainActor static func main() {
            let app = NSApplication.shared
            let delegate = Delegate()
            app.setActivationPolicy(.prohibited)
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        }
    }
    """#
}
