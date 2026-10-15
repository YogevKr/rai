import CryptoKit
import Foundation
import RaiCore
import XCTest
@testable import RaiApp

final class HerdrInstallerTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    func testDestinationUsesAccountOrExplicitLabPath() throws {
        XCTAssertEqual(try HerdrInstaller.destination(environment: [:], homeDirectory: "/account").path,
                       "/account/.local/bin/herdr")
        let root = try directory()
        let target = root.appendingPathComponent("bin/herdr")
        XCTAssertEqual(try HerdrInstaller.destination(environment: ["RAI_DATA_ROOT": root.path,
            "HERDR_BIN_PATH": target.path], homeDirectory: "/account"), target)
        XCTAssertThrowsError(try HerdrInstaller.destination(environment: ["RAI_DATA_ROOT": root.path], homeDirectory: "/account"))
        XCTAssertThrowsError(try HerdrInstaller.destination(environment: ["HERDR_BIN_PATH": "relative"], homeDirectory: "/account"))
    }

    func testVerifiedInstallationIsExecutableAndDoesNotOverwrite() throws {
        let root = try directory()
        let source = root.appendingPathComponent("download")
        let data = Data("#!/bin/sh\nexit 0\n".utf8)
        try data.write(to: source)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let target = root.appendingPathComponent("bin/herdr")
        try HerdrInstaller.install(download: source, checksum: digest, to: target, labRoot: root)
        XCTAssertEqual(try Data(contentsOf: target), data)
        XCTAssertTrue(ExecutableFile.isAvailable(at: target.path))
        XCTAssertThrowsError(try HerdrInstaller.install(download: source, checksum: digest, to: target, labRoot: root))
        XCTAssertEqual(try Data(contentsOf: target), data)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path), ["herdr"])
    }

    func testChecksumFailureLeavesNoInstallation() throws {
        let root = try directory()
        let source = root.appendingPathComponent("download")
        try Data("altered download".utf8).write(to: source)
        let target = root.appendingPathComponent("bin/herdr")
        XCTAssertThrowsError(try HerdrInstaller.install(download: source, checksum: String(repeating: "0", count: 64),
            to: target, labRoot: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testLabRejectsSymlinkOutsideItsRoot() throws {
        let root = try directory()
        let outside = try directory()
        let link = root.appendingPathComponent("bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try HerdrInstaller.destination(environment: ["RAI_DATA_ROOT": root.path,
            "HERDR_BIN_PATH": link.appendingPathComponent("herdr").path], homeDirectory: "/account"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testReleaseRequiresOfficialHTTPSAssetAndChecksum() throws {
        let checksum = String(repeating: "a", count: 64)
        let valid = URL(string: "https://github.com/herdrdev/herdr/releases/download/v0.9.1/herdr-macos-aarch64")!
        let release = HerdrInstaller.Release(version: "0.9.1", assets: ["macos-aarch64": valid], sha256: ["macos-aarch64": checksum])
        XCTAssertEqual(try release.asset(for: "macos-aarch64").0, valid)
        XCTAssertThrowsError(try release.asset(for: "macos-x86_64"))
        for url in ["http://github.com/herdrdev/herdr/releases/download/v1/herdr", "https://example.com/herdr",
                    "https://github.com/other/herdr/releases/download/v1/herdr"] {
            let release = HerdrInstaller.Release(version: "1", assets: ["mac": URL(string: url)!], sha256: ["mac": checksum])
            XCTAssertThrowsError(try release.asset(for: "mac"))
        }
        let malformed = HerdrInstaller.Release(version: "1", assets: ["mac": valid], sha256: ["mac": "invalid"])
        XCTAssertThrowsError(try malformed.asset(for: "mac"))
    }
}
