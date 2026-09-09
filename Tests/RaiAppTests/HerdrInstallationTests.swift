import AppKit
import RaiCore
import XCTest
@testable import RaiApp

final class HerdrInstallationTests: XCTestCase {
    func testInvalidOverrideExplainsHowToRecover() {
        let guidance = HerdrCLI.installationGuidance(environment: ["HERDR_BIN_PATH": "/custom/missing"])
        XCTAssertTrue(guidance.contains("/custom/missing"))
        XCTAssertTrue(guidance.contains("HERDR_BIN_PATH"))
        XCTAssertTrue(guidance.contains("restart Rai"))
        XCTAssertEqual(HerdrCLI.installationGuidance(environment: [:]),
                       "Install Herdr on this Mac, then select Retry.")
    }
    func testMissingExecutableDoesNotResolveToAnInventedPath() {
        XCTAssertNil(HerdrCLI.resolve(environment: [:], homeDirectory: "/test") { _ in false })
    }

    func testFindsInstallerAndCustomPathLocations() {
        for path in ["/opt/homebrew/bin/herdr", "/usr/local/bin/herdr",
                     "/test/.local/bin/herdr", "/custom/bin/herdr"] {
            XCTAssertEqual(HerdrCLI.resolve(
                environment: ["PATH": "/custom/bin"], homeDirectory: "/test"
            ) { $0 == path }, path)
        }
    }

    func testOverrideAndLabNeverFallBackToInstalledHerdr() {
        for environment in [["HERDR_BIN_PATH": "/missing/herdr"],
                            ["RAI_DATA_ROOT": "/lab"],
                            ["HERDR_BIN_PATH": "relative/herdr"]] {
            XCTAssertNil(HerdrCLI.resolve(environment: environment, homeDirectory: "/test") {
                $0 != "/missing/herdr"
            })
        }
    }

    func testFindsBinaryInstalledAfterFirstCheck() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("herdr")
        XCTAssertNil(HerdrCLI.resolve(environment: ["HERDR_BIN_PATH": root.path], homeDirectory: root.path))
        let environment = ["HERDR_BIN_PATH": binary.path]
        XCTAssertNil(HerdrCLI.resolve(environment: environment, homeDirectory: root.path))
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        XCTAssertEqual(HerdrCLI.resolve(environment: environment, homeDirectory: root.path), binary.path)
        let link = root.appendingPathComponent("herdr-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)
        XCTAssertEqual(HerdrCLI.resolve(environment: ["HERDR_BIN_PATH": link.path], homeDirectory: root.path), link.path)
        let lab = root.appendingPathComponent("lab")
        try FileManager.default.createDirectory(at: lab, withIntermediateDirectories: true)
        let lateBinary = lab.appendingPathComponent("herdr")
        let labEnvironment = ["RAI_DATA_ROOT": lab.path, "HERDR_BIN_PATH": lateBinary.path]
        XCTAssertNil(HerdrCLI.resolve(environment: labEnvironment, homeDirectory: root.path))
        try FileManager.default.createSymbolicLink(at: lateBinary, withDestinationURL: binary)
        XCTAssertTrue(ExecutableFile.isAvailable(at: lateBinary.path))
        XCTAssertNil(HerdrCLI.resolve(environment: labEnvironment, homeDirectory: root.path))
    }

    @MainActor
    func testMissingHerdrStopsStartupAndRetryWithoutAConnectionLoop() async throws {
        _ = NSApplication.shared
        let suite = "HerdrInstallationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "companionBridgeEnabled")
        let socket = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        var binary: String?
        let model = RaiModel(client: HerdrClient(socketPath: socket), userDefaults: defaults,
                             resolveHerdrBinary: { binary })
        model.start()
        XCTAssertTrue(model.needsHerdrInstallation)
        XCTAssertEqual(model.connectionState, .disconnected(model.herdrInstallationGuidance))
        XCTAssertNil(model.snapshot)
        XCTAssertNil(model.sessionAlert)
        model.retryHerdrStartup()
        XCTAssertTrue(model.needsHerdrInstallation)
        // A discovery check must keep Retry until a connection action resumes startup.
        binary = "/test/herdr"
        XCTAssertTrue(model.checkHerdrInstallation())
        XCTAssertTrue(model.needsHerdrInstallation)
        await model.shutdown()
    }
}
