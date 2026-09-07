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

    func testPruneRemovesOnlyCompletedUpdatesOfThisApp() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rai-prune-test-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Rai.app")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let completed = try staging(named: ".rai-update-done", beside: target, target: target, files: ["result.txt"])
        let inFlight = try staging(named: ".rai-update-live", beside: target, target: target, files: ["ready"])
        let otherApp = try staging(
            named: ".rai-update-other", beside: target,
            target: root.appendingPathComponent("Other.app"), files: ["result.txt"]
        )
        let unrelated = root.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
        try Data().write(to: unrelated.appendingPathComponent("result.txt"))
        let linked = root.appendingPathComponent(".rai-update-link")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: completed)

        // Compare names: the walk yields /private/var directory URLs, the fixture /var ones.
        XCTAssertEqual(
            AppUpdateInstallation.completedStagingDirectories(besideApplication: target).map(\.lastPathComponent),
            [completed.lastPathComponent]
        )
        XCTAssertEqual(
            AppUpdateInstallation.pruneCompletedStaging(besideApplication: target).map(\.lastPathComponent),
            [completed.lastPathComponent]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: completed.path))
        for kept in [inFlight, otherApp, unrelated, target] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path), kept.path)
        }
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: linked.path))
        XCTAssertEqual(AppUpdateInstallation.pruneCompletedStaging(besideApplication: target), [])
    }

    private func staging(named name: String, beside application: URL, target: URL, files: [String]) throws -> URL {
        let staging = application.deletingLastPathComponent().appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: staging.appendingPathComponent("Previous-Rai.app"), withIntermediateDirectories: true
        )
        let installation = AppUpdateInstallation(parentPID: 1, target: target, staging: staging, version: "0.1.49")
        try JSONEncoder().encode(installation).write(to: staging.appendingPathComponent("installation.json"))
        for file in files { try Data().write(to: staging.appendingPathComponent(file)) }
        return staging
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
