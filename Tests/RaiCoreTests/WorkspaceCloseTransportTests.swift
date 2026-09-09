import Foundation
import XCTest
@testable import RaiCore

final class WorkspaceCloseTransportTests: XCTestCase {
    func testReviewedClosureKeepsOneSocketAndStopsAfterServerReplacement() async throws {
        for mode in ["ok", "restart", "membership"] {
            try await withFixture(mode) { endpoint, snapshot, record in
                let preview = try XCTUnwrap(WorkspaceClosePreview(workspaces: EndpointLayoutRequest.workspaces(snapshot),
                    workspaceID: "w1", closeGroup: true, connectionID: "resource-generation"))
                do {
                    let count = try await endpoint.closeReviewedWorkspaces(preview)
                    XCTAssertEqual(mode, "ok")
                    XCTAssertEqual(count, 2)
                } catch {
                    XCTAssertNotEqual(mode, "ok", error.localizedDescription)
                    XCTAssertTrue(error.localizedDescription.contains("Closed 1 reviewed workspaces"))
                }
                let entries = try String(contentsOf: record).split(separator: "\n").map {
                    try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
                }
                XCTAssertEqual(entries.filter { $0.objectValue?["connection"] != nil }.count, 1,
                               "Closure must not connect to a replacement server")
                let activation = entries.filter { $0.objectValue?["method"] == .string("client_shell.surface.set") }
                XCTAssertEqual(activation.first?.objectValue?["params"]?.objectValue?["active"], .bool(true))
                let requests = entries.filter { $0.objectValue?["method"] == .string("workspace.close") }
                XCTAssertEqual(requests.count, mode == "ok" ? 2 : 1)
                XCTAssertEqual(requests.first?.objectValue?["params"]?.objectValue?["workspace_id"], .string("w2"))
                XCTAssertTrue(requests.allSatisfy { $0.objectValue?["params"]?.objectValue?["close_group"] == .bool(false) })
            }
        }
    }

    func testRealHerdrClosureOnOwnedDisposableServer() async throws {
        guard let path = ProcessInfo.processInfo.environment["RAI_WORKSPACE_CLOSE_TEST_ROOT"] else {
            throw XCTSkip("Set RAI_WORKSPACE_CLOSE_TEST_ROOT to an owned disposable Herdr fixture.")
        }
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard root.path.hasPrefix("/private/tmp/rai-close-real-") || root.path.hasPrefix("/tmp/rai-close-real-") else {
            XCTFail("The fixture root is not owned"); return
        }
        guard try String(contentsOf: root.appendingPathComponent(".rai-closure-owned")) == "metadata-rules-closure" else {
            XCTFail("The fixture ownership marker does not match"); return
        }
        let endpoint = HerdrEndpointConnection()
        defer { endpoint.disconnect() }
        let snapshot = try await endpoint.connect(socketPath: root.appendingPathComponent("config/herdr/sessions/closure/herdr-client.sock").path)
        let allWorkspaces = try EndpointLayoutRequest.workspaces(snapshot)
        let workspaces = allWorkspaces.filter { $0.label.hasPrefix("Close Validation ") }
        XCTAssertEqual(workspaces.count, 2)
        guard workspaces.count == 2, workspaces.allSatisfy({ $0.label.hasPrefix("Close Validation ") }) else {
            XCTFail("The fixture contains unexpected workspaces"); return
        }
        var closed = Set<String>()
        for workspace in workspaces where !closed.contains(workspace.workspaceID) {
            let group = WorkspaceClosePreview.group(in: workspaces, workspaceID: workspace.workspaceID)
            let preview = try XCTUnwrap(WorkspaceClosePreview(workspaces: workspaces, workspaceID: workspace.workspaceID,
                                                             closeGroup: group.count > 1, connectionID: "owned-fixture"))
            let count = try await endpoint.closeReviewedWorkspaces(preview)
            XCTAssertEqual(count, preview.workspaceIDs.count)
            closed.formUnion(preview.workspaceIDs)
        }
        let client = HerdrClient(socketPath: root.appendingPathComponent("config/herdr/sessions/closure/herdr.sock").path)
        defer { client.disconnect() }
        let remaining = try await client.snapshot().workspaces.map(\.workspaceID)
        XCTAssertTrue(Set(remaining).isDisjoint(with: closed))
        let untouched = Set(allWorkspaces.map(\.workspaceID)).subtracting(closed)
        XCTAssertTrue(untouched.isSubset(of: Set(remaining)))
    }

    private func withFixture(_ mode: String,
                             run: (HerdrEndpointConnection, HerdrEndpointSnapshot, URL) async throws -> Void) async throws {
        let root = URL(fileURLWithPath: "/tmp/rai-close-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let socket = root.appendingPathComponent("endpoint.sock")
        let record = root.appendingPathComponent("requests.jsonl")
        let script = try XCTUnwrap(Bundle.module.url(forResource: "fake_workspace_close", withExtension: "py", subdirectory: "Fixtures"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, socket.path, mode, record.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.standardError
        let endpoint = HerdrEndpointConnection()
        defer {
            endpoint.disconnect()
            if process.isRunning { process.terminate() }
            try? FileManager.default.removeItem(at: root)
        }
        try process.run()
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: socket.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let snapshot = try await endpoint.connect(socketPath: socket.path)
        try await run(endpoint, snapshot, record)
    }
}
