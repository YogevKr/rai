#if os(macOS)
import XCTest
@testable import RaiCore

final class AppUpdateInstallationTests: XCTestCase {
    func testReplacementPreservesThePreviousBundle() throws {
        let (root, installation) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try installation.replaceApplication()
        XCTAssertEqual(try marker(in: installation.target), "new")
        XCTAssertEqual(try marker(in: installation.backup), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: installation.candidate.path))
    }

    func testFailedReplacementRestoresThePreviousBundle() throws {
        let (root, installation) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try installation.replaceApplication { source, destination in
            if source == installation.candidate { throw CocoaError(.fileWriteUnknown) }
            try FileManager.default.moveItem(at: source, to: destination)
        }) { XCTAssertEqual($0 as? AppUpdateError, .installationFailed) }
        XCTAssertEqual(try marker(in: installation.target), "old")
        XCTAssertEqual(try marker(in: installation.candidate), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: installation.backup.path))
    }

    func testRollbackFailureRetainsTheBackupAndReportsIt() throws {
        let (root, installation) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try installation.replaceApplication { source, destination in
            guard source == installation.target else { throw CocoaError(.fileWriteUnknown) }
            try FileManager.default.moveItem(at: source, to: destination)
        }) { XCTAssertEqual($0 as? AppUpdateError, .rollbackFailed) }
        XCTAssertEqual(try marker(in: installation.backup), "old")
        XCTAssertEqual(try marker(in: installation.candidate), "new")
    }

    func testExistingBackupIsNeverOverwritten() throws {
        let (root, installation) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: installation.backup, withIntermediateDirectories: false)
        XCTAssertThrowsError(try installation.replaceApplication())
        XCTAssertEqual(try marker(in: installation.target), "old")
    }

    func testSymlinkedCandidateIsRejected() throws {
        let (root, installation) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let alternate = root.appendingPathComponent("alternate.app")
        try FileManager.default.moveItem(at: installation.candidate, to: alternate)
        try FileManager.default.createSymbolicLink(at: installation.candidate, withDestinationURL: alternate)
        XCTAssertThrowsError(try installation.replaceApplication())
        XCTAssertEqual(try marker(in: installation.target), "old")
    }

    func testUnsignedAppCannotPassVerification() throws {
        let (root, installation) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = installation.candidate.appendingPathComponent("Contents")
        let executable = contents.appendingPathComponent("MacOS/rai")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("unsigned".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let info = ["CFBundleIdentifier": "gr.krig.rai", "CFBundleShortVersionString": "0.1.49", "CFBundleExecutable": "rai"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        XCTAssertThrowsError(try AppUpdateVerification.verifyApplication(at: installation.candidate, version: "0.1.49")) {
            XCTAssertEqual($0 as? AppUpdateError, .invalidSignature)
        }
        XCTAssertThrowsError(try AppUpdateVerification.verifyApplication(at: installation.candidate, version: "0.1.50")) {
            XCTAssertEqual($0 as? AppUpdateError, .invalidApplication)
        }
    }

    private func fixture() throws -> (URL, AppUpdateInstallation) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rai-update-test-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let installation = AppUpdateInstallation(
            parentPID: ProcessInfo.processInfo.processIdentifier,
            target: root.appendingPathComponent("Rai.app"),
            staging: root.appendingPathComponent(".rai-update-test"), version: "0.1.49"
        )
        try FileManager.default.createDirectory(at: installation.target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installation.candidate, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: installation.target.appendingPathComponent("marker"))
        try Data("new".utf8).write(to: installation.candidate.appendingPathComponent("marker"))
        return (root, installation)
    }

    private func marker(in directory: URL) throws -> String {
        try String(contentsOf: directory.appendingPathComponent("marker"))
    }
}
#endif
