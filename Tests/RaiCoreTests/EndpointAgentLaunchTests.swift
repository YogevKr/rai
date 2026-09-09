import Foundation
import XCTest
@testable import RaiCore

final class EndpointAgentLaunchTests: XCTestCase {
    func testLaunchRequiresCapturedBootPaneAndDocumentedName() throws {
        let snapshot = try JSONDecoder().decode(HerdrEndpointSnapshot.self, from: Data(
            #"{"boot_id":"boot","revision":1,"panes":[{"pane_id":"w1:p1"}]}"#.utf8))
        for invalid in ["Codex", "", "9codex", "a b", "a;echo", String(repeating: "a", count: 33)] {
            XCTAssertFalse(EndpointAgentLaunchRequest.isValidName(invalid))
        }
        let request = EndpointAgentLaunchRequest(bootID: "boot", owningViewID: UUID(), paneID: "w1:p1", name: "codex-1", kind: .codex)
        try request.validate(in: snapshot)
        XCTAssertEqual(request.params["pane_id"], .string("w1:p1"))
        XCTAssertEqual(request.params["kind"], .string("codex"))
        XCTAssertThrowsError(try EndpointAgentLaunchRequest(bootID: "old", owningViewID: UUID(), paneID: "w1:p1", name: "codex", kind: .codex).validate(in: snapshot))
        XCTAssertThrowsError(try EndpointAgentLaunchRequest(bootID: "boot", owningViewID: UUID(), paneID: "other", name: "codex", kind: .codex).validate(in: snapshot))
        XCTAssertThrowsError(try request.validateResult(.object(["agent": .object(["pane_id": .string("other")])])))
    }

    func testFocusFailurePreservesSuccessfulLaunchAndWrongPaneNeverFocuses() async throws {
        let request = EndpointAgentLaunchRequest(bootID: "boot", owningViewID: UUID(), paneID: "w1:p1", name: "codex", kind: .codex)
        let response = JSONValue.object(["agent": .object(["pane_id": .string("w1:p1")])])
        let result = try await request.resultAfterLaunch(response) { throw HerdrEndpointError.staleIdentity }
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.message.contains("Agent started"))
        XCTAssertTrue(result.message.contains("could not receive focus"))
        var focused = false
        do {
            _ = try await request.resultAfterLaunch(.object([:])) { focused = true }
            XCTFail("A malformed launch response must fail.")
        } catch { XCTAssertFalse(focused) }
    }

    func testPinnedRequestRejectsStaleBootBeforeWritingAndNeverRetries() async throws {
        try await withFixture("ok") { root in
            let client = HerdrPinnedRPC()
            do {
                _ = try await client.request(socketPath: root.appendingPathComponent("api.sock").path,
                    endpointSocketPath: root.appendingPathComponent("endpoint.sock").path, bootID: "old",
                    method: "agent.start", params: [:], validate: { _ in })
                XCTFail("Old boot must fail.")
            } catch { XCTAssertEqual(error as? HerdrEndpointError, .staleIdentity) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("api.jsonl").path))
        }
        for mode in ["ok", "wrong", "stall"] {
            try await withFixture(mode) { root in
                let client = HerdrPinnedRPC()
                do {
                    let value = try await client.request(socketPath: root.appendingPathComponent("api.sock").path,
                        endpointSocketPath: root.appendingPathComponent("endpoint.sock").path, bootID: "boot",
                        method: "agent.start", params: [:], timeout: .milliseconds(100), validate: { _ in })
                    XCTAssertEqual(mode, "ok")
                    XCTAssertEqual(value.objectValue?["agent"]?.objectValue?["pane_id"], .string("w1:p1"))
                } catch { XCTAssertNotEqual(mode, "ok") }
                let data = try Data(contentsOf: root.appendingPathComponent("api.jsonl"))
                XCTAssertEqual(data.split(separator: 10).count, 1)
            }
        }
    }

    private func withFixture(_ mode: String, run: (URL) async throws -> Void) async throws {
        let root = URL(fileURLWithPath: "/tmp/rai-launch-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var processes: [Process] = []
        defer {
            for process in processes where process.isRunning { process.terminate() }
            try? FileManager.default.removeItem(at: root)
        }
        for (scriptName, socketName, fixtureMode, recordName) in [
            ("fake_endpoint_server", "endpoint.sock", "basic", "endpoint.jsonl"),
            ("fake_pinned_rpc", "api.sock", mode, "api.jsonl")
        ] {
            let script = try XCTUnwrap(Bundle.module.url(forResource: scriptName, withExtension: "py", subdirectory: "Fixtures"))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [script.path, root.appendingPathComponent(socketName).path, fixtureMode, root.appendingPathComponent(recordName).path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); processes.append(process)
        }
        for _ in 0..<200 {
            if ["api.sock", "endpoint.sock"].allSatisfy({ FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await run(root)
    }
}
