import Foundation
import XCTest
@testable import RaiCore

final class AppDataPathsTests: XCTestCase {
    func testLabRecordsServersCreatedByTheApp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("bin/herdr").path
        let socket = root.appendingPathComponent("herdr.sock").path
        try LabLaunch.recordServer(pid: 123, executable: executable, socketPath: socket, root: root)
        let data = try Data(contentsOf: root.appendingPathComponent("herdr-123.json"))
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(record["pid"] as? Int, 123)
        XCTAssertEqual(record["executable"] as? String, executable)
        XCTAssertEqual(record["socket"] as? String, socket)
        XCTAssertThrowsError(try LabLaunch.recordServer(pid: 124, executable: "/live/herdr", socketPath: socket, root: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("herdr-124.json").path))
    }

    func testLabActionsRejectExternalAndLinkedTargets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside"),
                                                   withDestinationURL: root.deletingLastPathComponent())
        XCTAssertNoThrow(try LabLaunch.requireContainedPath(root.appendingPathComponent("claude/settings.json").path, root: root))
        for path in [root.appendingPathComponent("outside/settings.json").path,
                     root.path + "/../settings.json", "/settings.json"] {
            XCTAssertThrowsError(try LabLaunch.requireContainedPath(path, root: root))
        }
        XCTAssertNoThrow(try LabLaunch.requireContainedPath("/settings.json", root: nil))
        XCTAssertThrowsError(try LabLaunch.requireRemoteAccess(isIsolated: true))
        XCTAssertNoThrow(try LabLaunch.requireRemoteAccess(isIsolated: false))
    }

    func testProductionPathsStayUnchanged() {
        let paths = AppDataPaths(
            environment: [:], home: URL(fileURLWithPath: "/home/user"),
            support: URL(fileURLWithPath: "/support")
        )
        XCTAssertFalse(paths.isIsolated)
        XCTAssertEqual(paths.applicationSupport.path, "/support/Rai")
        XCTAssertEqual(paths.claudeDirectory.path, "/home/user/.claude")
        XCTAssertEqual(paths.herdrConfigFile.path, "/home/user/.config/herdr/config.toml")
    }

    func testLabPathsDoNotUseUserStores() {
        let paths = AppDataPaths(environment: [
            "RAI_DATA_ROOT": "/tmp/rai-test-a", "HERDR_CONFIG_PATH": "/tmp/rai-test-a/config.toml"
        ])
        XCTAssertTrue(paths.isIsolated)
        XCTAssertEqual(paths.applicationSupport.path, "/tmp/rai-test-a/support")
        XCTAssertEqual(paths.claudeDirectory.path, "/tmp/rai-test-a/claude")
        XCTAssertEqual(paths.herdrConfigFile.path, "/tmp/rai-test-a/config.toml")
        let other = AppDataPaths(environment: ["RAI_DATA_ROOT": "/tmp/rai-test-b"])
        XCTAssertNotEqual(paths.applicationSupport, other.applicationSupport)
    }

    func testLabRejectsMissingConfigurationAndForeignPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = "gr.krig.rai.lab.test"
        try bundle.write(to: root.appendingPathComponent(".rai-lab-owned"), atomically: true, encoding: .utf8)
        var environment = ["RAI_DATA_ROOT": root.path, "RAI_BRIDGE_PORT": "49871"]
        for key in ["HERDR_SOCKET_PATH", "HERDR_CONFIG_PATH", "HERDR_BIN_PATH", "RAI_HOOK_SOCKET_PATH",
                    "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "RAI_PAIRING_CODE_FILE",
                    "TMPDIR", "CLAUDE_CONFIG_DIR", "CODEX_HOME", "ZDOTDIR", "GIT_CONFIG_GLOBAL"] {
            environment[key] = root.appendingPathComponent(key).path
        }
        let executable = root.appendingPathComponent("HERDR_BIN_PATH")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        XCTAssertNoThrow(try LabLaunch.validate(bundleIdentifier: bundle, environment: environment))
        var directoryBinary = environment
        directoryBinary["HERDR_BIN_PATH"] = root.path
        XCTAssertThrowsError(try LabLaunch.validate(bundleIdentifier: bundle, environment: directoryBinary))
        var missingBinary = environment
        missingBinary["HERDR_BIN_PATH"] = root.appendingPathComponent("missing/herdr").path
        XCTAssertThrowsError(try LabLaunch.validate(bundleIdentifier: bundle, environment: missingBinary))
        missingBinary["RAI_LAB_ALLOW_MISSING_HERDR"] = "1"
        XCTAssertNoThrow(try LabLaunch.validate(bundleIdentifier: bundle, environment: missingBinary))
        missingBinary["HERDR_BIN_PATH"] = "/missing/herdr"
        XCTAssertThrowsError(try LabLaunch.validate(bundleIdentifier: bundle, environment: missingBinary))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: executable.path)
        XCTAssertThrowsError(try LabLaunch.validate(bundleIdentifier: bundle, environment: environment))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        XCTAssertThrowsError(try LabLaunch.validate(bundleIdentifier: bundle, environment: [:]))
        for key in environment.keys {
            var missing = environment
            missing.removeValue(forKey: key)
            XCTAssertThrowsError(try LabLaunch.validate(bundleIdentifier: bundle, environment: missing), key)
        }
        environment["HERDR_SOCKET_PATH"] = root.path + "/../live.sock"
        XCTAssertThrowsError(try LabLaunch.validate(bundleIdentifier: bundle, environment: environment))
    }

    func testConfigFileOverrideDoesNotMoveSessionStorage() {
        let paths = AppDataPaths(environment: [
            "XDG_CONFIG_HOME": "/tmp/config-root", "HERDR_CONFIG_PATH": "/tmp/custom.toml"
        ])
        XCTAssertEqual(paths.herdrConfigFile.path, "/tmp/custom.toml")
        XCTAssertEqual(paths.herdrDirectory.path, "/tmp/config-root/herdr")
        let empty = AppDataPaths(environment: ["XDG_CONFIG_HOME": "", "HERDR_CONFIG_PATH": ""],
                                 home: URL(fileURLWithPath: "/home/user"))
        XCTAssertEqual(empty.herdrDirectory.path, "/home/user/.config/herdr")
        XCTAssertEqual(empty.herdrConfigFile.path, "/home/user/.config/herdr/config.toml")
    }

    func testLabBlocksIntegrationPathsWithoutSupportedOverrides() {
        let lab = AppDataPaths(environment: ["RAI_DATA_ROOT": "/tmp/lab"])
        XCTAssertTrue(lab.canManageIntegration("claude"))
        XCTAssertTrue(lab.canManageIntegration("codex"))
        XCTAssertFalse(lab.canManageIntegration("droid"))
        XCTAssertFalse(lab.canManageIntegration("future-agent"))
        XCTAssertTrue(AppDataPaths(environment: [:]).canManageIntegration("droid"))
    }

    func testLabRejectsSymlinkOutsideItsRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = "gr.krig.rai.lab.test"
        try bundle.write(to: root.appendingPathComponent(".rai-lab-owned"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("outside").path, withDestinationPath: "/")
        XCTAssertThrowsError(try LabLaunch.validate(bundleIdentifier: bundle, environment: [
            "RAI_DATA_ROOT": root.path, "HERDR_SOCKET_PATH": root.appendingPathComponent("outside/live.sock").path
        ])) { error in
            XCTAssertTrue(error.localizedDescription.contains("HERDR_SOCKET_PATH"))
        }
    }
}
