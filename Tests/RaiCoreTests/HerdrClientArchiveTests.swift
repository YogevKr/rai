import Foundation
import XCTest
@testable import RaiCore

final class HerdrClientArchiveTests: XCTestCase {
    func testRetainedClientSurvivesInstallationReplacementAndAppRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("herdr")
        try Data("protocol22".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: source.path)
        let directory = root.appendingPathComponent("archive")
        let archived = try await HerdrClientArchive(directory: directory).retain(source: source, protocolVersion: 22) { file in
            XCTAssertEqual(try Data(contentsOf: file), Data("protocol22".utf8))
            return 22
        }
        try Data("protocol23".utf8).write(to: source)
        let restarted = HerdrClientArchive(directory: directory)
        XCTAssertEqual(restarted.executable(for: 22), archived)
        XCTAssertNil(restarted.executable(for: 23))
        XCTAssertEqual(try Data(contentsOf: archived), Data("protocol22".utf8))
        let reused = try await restarted.retain(source: source, protocolVersion: 22) { file in
            XCTAssertEqual(file, archived)
            return 22
        }
        XCTAssertEqual(reused, archived)
    }

    func testProtocolMismatchLeavesInstallationAndArchiveUnchanged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("herdr")
        let original = Data("protocol23".utf8)
        try original.write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: source.path)
        let archive = HerdrClientArchive(directory: root.appendingPathComponent("archive"))
        do {
            _ = try await archive.retain(source: source, protocolVersion: 22) { _ in 23 }
            XCTFail("Must reject a mismatched client")
        } catch {
            XCTAssertNil(archive.executable(for: 22))
            XCTAssertEqual(try Data(contentsOf: source), original)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: archive.directory.path), [])
        }
    }
}
