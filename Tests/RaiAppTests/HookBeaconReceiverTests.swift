import Foundation
import XCTest

@testable import RaiApp
@testable import RaiCore

final class HookBeaconReceiverTests: XCTestCase {
    func testBeaconLifecycleKeepsPreBlockContextAcrossWorkingRefresh() {
        let context = AgentBeacon(
            event: "PreToolUse",
            sessionID: "session-1",
            cwd: "/repo",
            transcriptPath: "/tmp/session.jsonl",
            toolName: "Bash",
            toolInput: .object(["command": .string("swift test")]),
            timestamp: 1
        )

        XCTAssertTrue(AgentBeaconLifecycle.keepsActiveBeacon(
            context,
            previousStatus: .idle,
            newStatus: .working
        ))
        XCTAssertFalse(AgentBeaconLifecycle.keepsActiveBeacon(
            context,
            previousStatus: .working,
            newStatus: .done
        ))
    }

    func testBeaconLifecycleExpiresResolvedPendingRequest() {
        let request = AgentBeacon(
            event: "PermissionRequest",
            sessionID: "session-1",
            cwd: "/repo",
            transcriptPath: "/tmp/session.jsonl",
            toolName: "Bash",
            toolInput: .object(["command": .string("swift test")]),
            timestamp: 1
        )

        XCTAssertFalse(AgentBeaconLifecycle.keepsActiveBeacon(
            request,
            previousStatus: .blocked,
            newStatus: .working
        ))
        XCTAssertFalse(AgentBeaconLifecycle.keepsActiveBeacon(
            request,
            previousStatus: .blocked,
            newStatus: nil
        ))
    }

    func testBeaconLifecycleKeepsOnlyAnUnpresentedOrNewRunCompletion() {
        XCTAssertTrue(AgentBeaconLifecycle.keepsCompletion(
            completionTimestamp: 20,
            presentedTimestamp: nil,
            latestWorkTimestamp: 10
        ))
        XCTAssertFalse(AgentBeaconLifecycle.keepsCompletion(
            completionTimestamp: 20,
            presentedTimestamp: 20,
            latestWorkTimestamp: 10
        ))
        XCTAssertTrue(AgentBeaconLifecycle.keepsCompletion(
            completionTimestamp: 40,
            presentedTimestamp: 20,
            latestWorkTimestamp: 30
        ))
    }

    func testClaudeSettingsURLHonorsConfiguredDirectory() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)

        XCTAssertEqual(
            ClaudeHooksInstaller.settingsURL(
                environment: ["CLAUDE_CONFIG_DIR": "/tmp/claude-test"],
                homeDirectory: home
            ).path,
            "/tmp/claude-test/settings.json"
        )
        XCTAssertEqual(
            ClaudeHooksInstaller.settingsURL(environment: [:], homeDirectory: home).path,
            "/Users/test/.claude/settings.json"
        )
    }

    func testRemovingHooksKeepsMissingSettingsAndSharedScript() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let defaults = UserDefaults()
        let settingsURL = fixture.directory.appendingPathComponent("settings.json")
        let scriptURL = fixture.directory.appendingPathComponent("rai-hook.sh")
        try Data("hook".utf8).write(to: scriptURL)
        let preview = try ClaudeHooksInstaller.makePreview(
            action: .remove,
            settingsURL: settingsURL,
            scriptURL: scriptURL,
            bundledScriptURL: nil
        )

        try ClaudeHooksInstaller.apply(preview, userDefaults: defaults)

        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: scriptURL.path))
    }

    func testHookInstallerTracksEachManagedSettingsPath() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let defaults = UserDefaults()
        let first = fixture.directory.appendingPathComponent("first.json")
        let second = fixture.directory.appendingPathComponent("second.json")
        let scriptURL = fixture.directory.appendingPathComponent("rai-hook.sh")
        let bundled = fixture.directory.appendingPathComponent("bundled-hook.sh")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: bundled)

        for settingsURL in [first, second] {
            let preview = try ClaudeHooksInstaller.makePreview(
                action: .install,
                settingsURL: settingsURL,
                scriptURL: scriptURL,
                bundledScriptURL: bundled
            )
            try ClaudeHooksInstaller.apply(preview, userDefaults: defaults)
        }
        XCTAssertTrue(ClaudeHooksInstaller.hasManagedHooks(userDefaults: defaults))

        let removeFirst = try ClaudeHooksInstaller.makePreview(
            action: .remove,
            settingsURL: first,
            scriptURL: scriptURL,
            bundledScriptURL: nil
        )
        try ClaudeHooksInstaller.apply(removeFirst, userDefaults: defaults)
        XCTAssertTrue(ClaudeHooksInstaller.hasManagedHooks(userDefaults: defaults))

        let removeSecond = try ClaudeHooksInstaller.makePreview(
            action: .remove,
            settingsURL: second,
            scriptURL: scriptURL,
            bundledScriptURL: nil
        )
        try ClaudeHooksInstaller.apply(removeSecond, userDefaults: defaults)
        XCTAssertFalse(ClaudeHooksInstaller.hasManagedHooks(userDefaults: defaults))
    }

    func testHookInstallerRejectsLinkedSettingsFile() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let target = fixture.directory.appendingPathComponent("managed.json")
        let link = fixture.directory.appendingPathComponent("settings.json")
        try Data("{}\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(
            try ClaudeHooksInstaller.makePreview(
                action: .remove,
                settingsURL: link,
                scriptURL: fixture.directory.appendingPathComponent("rai-hook.sh"),
                bundledScriptURL: nil
            )
        ) { error in
            guard case ClaudeHooksInstallerError.linkedSettings = error else {
                return XCTFail("Expected linked settings error, got \(error)")
            }
        }
    }

    func testReceiverSocketRoundTrip() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let received = expectation(description: "received beacon")
        let captured = LockedBeacon()
        let receiver = HookBeaconReceiver(socketURL: fixture.socketURL) { beacon in
            captured.set(beacon)
            received.fulfill()
        }
        try receiver.start()
        defer { receiver.stop() }

        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: fixture.socketURL.path)[
                .posixPermissions
            ] as? NSNumber
        )
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)

        let socket = try UnixSocket(path: fixture.socketURL.path)
        try socket.writeLine(Data(samplePayload(event: "PermissionRequest").utf8))
        wait(for: [received], timeout: 2)

        let beacon = captured.value
        XCTAssertEqual(beacon?.paneID, "w9:p4")
        XCTAssertEqual(beacon?.pendingSummary, "Bash: swift test")
    }

    func testHookScriptAddsEventAndPaneID() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let received = expectation(description: "script beacon")
        let captured = LockedBeacon()
        let receiver = HookBeaconReceiver(socketURL: fixture.socketURL) { beacon in
            captured.set(beacon)
            received.fulfill()
        }
        try receiver.start()
        defer { receiver.stop() }

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = repositoryRoot.appendingPathComponent("Resources/rai-hook.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, "PreToolUse"]
        var environment = ProcessInfo.processInfo.environment
        environment["RAI_HOOK_SOCKET_PATH"] = fixture.socketURL.path
        environment["HERDR_PANE_ID"] = "w3:p7"
        environment["HERDR_SOCKET_PATH"] = "/tmp/herdr-test.sock"
        process.environment = environment
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(samplePayload(event: nil).utf8))
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        wait(for: [received], timeout: 3)
        let beacon = captured.value
        XCTAssertEqual(beacon?.event, "PreToolUse")
        XCTAssertEqual(beacon?.paneID, "w3:p7")
        XCTAssertEqual(beacon?.herdrSocketPath, "/tmp/herdr-test.sock")
        XCTAssertNotNil(beacon?.parentPID)
        if let timestamp = beacon?.timestamp {
            XCTAssertNotEqual(timestamp, floor(timestamp))
        }
    }

    func testSecondReceiverCannotStealLiveSocket() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let received = expectation(description: "first receiver stays active")
        let first = HookBeaconReceiver(socketURL: fixture.socketURL) { _ in
            received.fulfill()
        }
        try first.start()
        defer { first.stop() }

        let second = HookBeaconReceiver(socketURL: fixture.socketURL) { _ in }
        XCTAssertThrowsError(try second.start()) { error in
            guard case HookBeaconReceiverError.activeSocket = error else {
                return XCTFail("Expected active socket error, got \(error)")
            }
        }
        second.stop()

        let socket = try UnixSocket(path: fixture.socketURL.path)
        try socket.writeLine(Data(samplePayload(event: "PermissionRequest").utf8))
        wait(for: [received], timeout: 2)
    }

    private func samplePayload(event: String?) -> String {
        var object: [String: Any] = [
            "session_id": "session-1",
            "cwd": "/repo",
            "transcript_path": "/tmp/session.jsonl",
            "tool_name": "Bash",
            "tool_input": ["command": "swift test"],
        ]
        if let event {
            object["event"] = event
            object["ts"] = 1_780_000_000
            object["pane_id"] = "w9:p4"
        }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    private final class Fixture {
        let directory: URL
        let socketURL: URL

        init() throws {
            directory = URL(fileURLWithPath: "/tmp")
                .appendingPathComponent("rai-hook-tests-\(UUID().uuidString.prefix(8))")
            socketURL = directory.appendingPathComponent("hooks.sock")
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private final class LockedBeacon: @unchecked Sendable {
        private let lock = NSLock()
        private var beacon: AgentBeacon?

        var value: AgentBeacon? {
            lock.lock()
            defer { lock.unlock() }
            return beacon
        }

        func set(_ value: AgentBeacon) {
            lock.lock()
            beacon = value
            lock.unlock()
        }
    }
}
