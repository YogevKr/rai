import Foundation
import XCTest
@testable import RaiCore

final class LegacyWorkspaceCloseTransportTests: XCTestCase {
    func testProtocol20OrdinaryClosureUsesTheSocketOpenedBeforeValidation() async throws {
        for mode in ["ok", "replace"] {
            try await withFixture(mode) { path, preview, record in
                try await HerdrPinnedRPC().closeReviewedLegacyWorkspace(socketPath: path, preview: preview,
                    connectionID: "reviewed", validateConnection: {})
                let entries = try self.entries(record)
                let writes = self.closures(entries)
                XCTAssertEqual(writes.count, 1)
                XCTAssertEqual(writes.first?.objectValue?["connection"], .number(1))
                XCTAssertEqual(writes.first?.objectValue?["server"], .string("original"))
                XCTAssertEqual(writes.first?.objectValue?["request"]?.objectValue?["params"]?.objectValue?["close_group"], .bool(false))
                XCTAssertEqual(entries.filter { $0.objectValue?["connection"] != nil && $0.objectValue?["request"] == nil }.count, 2)
            }
        }
    }

    func testLegacyClosureRejectsChangedWorkspaceMetadataGroupsAndResourceGeneration() async throws {
        for mode in ["missing", "metadata", "group", "unknown_primary", "generation"] {
            try await withFixture(mode) { path, preview, record in
                do {
                    try await HerdrPinnedRPC().closeReviewedLegacyWorkspace(socketPath: path, preview: preview,
                        connectionID: "reviewed", validateConnection: {
                            if mode == "generation" { throw HerdrEndpointError.staleIdentity }
                        })
                    XCTFail("Changed workspace or unsafe primary must fail: \(mode)")
                } catch { }
                XCTAssertTrue(self.closures(try self.entries(record)).isEmpty)
            }
        }
    }

    func testLegacyClosureNeverReplaysAnAmbiguousWriteOnAReplacementServer() async throws {
        try await withFixture("drop_reply") { path, preview, record in
            do {
                try await HerdrPinnedRPC().closeReviewedLegacyWorkspace(socketPath: path, preview: preview,
                    connectionID: "reviewed", validateConnection: {})
                XCTFail("A dropped reply must fail")
            } catch { }
            let entries = try self.entries(record)
            XCTAssertEqual(self.closures(entries).count, 1)
            XCTAssertFalse(entries.contains { $0.objectValue?["server"] == .string("replacement") })
        }
    }

    func testLegacyClosureDeadlineAndCancellationCloseBothSocketsDuringValidation() async throws {
        for cancel in [false, true] {
            try await withFixture("stall") { path, preview, record in
                let clock = ContinuousClock()
                let start = clock.now
                let task = Task {
                    try await HerdrPinnedRPC().closeReviewedLegacyWorkspace(socketPath: path, preview: preview,
                        connectionID: "reviewed", timeout: cancel ? .seconds(20) : .milliseconds(200), validateConnection: {})
                }
                if cancel {
                    try await self.waitForRecords(record, count: 1, key: "request")
                    task.cancel()
                }
                do { try await task.value; XCTFail("Stalled validation must fail") }
                catch { if !cancel { XCTAssertEqual(error as? HerdrEndpointError, .timedOut) } }
                XCTAssertLessThan(start.duration(to: clock.now), .seconds(2))
                try await self.waitForRecords(record, count: 2, key: "closed")
                let entries = try self.entries(record)
                XCTAssertEqual(entries.filter { $0.objectValue?["closed"] != nil }.count, 2)
                XCTAssertTrue(self.closures(entries).isEmpty)
            }
        }
    }

}

private extension LegacyWorkspaceCloseTransportTests {
    private func waitForRecords(_ record: URL, count: Int, key: String) async throws {
        for _ in 0..<100 {
            if try entries(record).filter({ $0.objectValue?[key] != nil }).count == count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected \(count) records for \(key)")
    }

    private func closures(_ entries: [JSONValue]) -> [JSONValue] {
        entries.filter { $0.objectValue?["request"]?.objectValue?["method"] == .string("workspace.close") }
    }

    private func entries(_ record: URL) throws -> [JSONValue] {
        guard FileManager.default.fileExists(atPath: record.path) else { return [] }
        return try Data(contentsOf: record).split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
    }

    private func withFixture(_ mode: String,
        run: (String, WorkspaceClosePreview, URL) async throws -> Void) async throws {
        let root = URL(fileURLWithPath: "/tmp/rai-close-old-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let socket = root.appendingPathComponent("api.sock")
        let record = root.appendingPathComponent("requests.jsonl")
        let script = try XCTUnwrap(Bundle.module.url(forResource: "fake_legacy_workspace_close", withExtension: "py", subdirectory: "Fixtures"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, socket.path, mode, record.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        defer {
            if process.isRunning { process.terminate() }
            try? FileManager.default.removeItem(at: root)
        }
        try process.run()
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: socket.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(contentsOf: URL(fileURLWithPath: record.path + ".preview")))
        let preview = try XCTUnwrap(WorkspaceClosePreview(snapshot: snapshot, workspaceID: "w1", closeGroup: false, connectionID: "reviewed"))
        try await run(socket.path, preview, record)
    }
}
