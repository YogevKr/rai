import Foundation
import XCTest
@testable import RaiCore

final class NotificationInputTransportTests: XCTestCase {
    func testSameHostSendsTextBeforeEnterOnLegacyAndNativeConnections() async throws {
        for native in [false, true] {
            try await withFixture { fixture in
                let host = NotificationInputHost()
                try await fixture.client.sendInput(paneID: "phone", bytes: Array("answer\r".utf8),
                    endpointIdentity: native ? fixture.identity : nil, validateBeforeSend: { try await host.validate() })
                let requests = try fixture.requests()
                XCTAssertEqual(requests.count, 2)
                XCTAssertEqual(requests.map { $0["method"] as? String }, ["pane.send_input", "pane.send_input"])
                let params = try requests.map { try XCTUnwrap($0["params"] as? [String: Any]) }
                XCTAssertEqual(params[0]["text"] as? String, "answer")
                XCTAssertEqual(params[1]["keys"] as? [String], ["enter"])
                XCTAssertTrue(params.allSatisfy { $0["pane_id"] as? String == "phone" })
                let validations = await host.validations
                XCTAssertEqual(validations, 2)
            }
        }
    }

    func testHostChangeDuringSubmitDelayPreventsEnter() async throws {
        for native in [false, true] {
            try await withFixture { fixture in
                let host = NotificationInputHost()
                let pending = Task {
                    try await fixture.client.sendInput(paneID: "phone", bytes: Array("answer\r".utf8),
                        endpointIdentity: native ? fixture.identity : nil, validateBeforeSend: { try await host.validate() })
                }
                defer { pending.cancel() }
                try await fixture.waitForRequestCount(1)
                await host.replaceHost()
                do { try await pending.value; XCTFail("A changed host must reject Enter.") }
                catch { XCTAssertEqual(error as? HerdrEndpointError, .staleIdentity) }
                XCTAssertEqual(try fixture.requests().count, 1)
                let validations = await host.validations
                XCTAssertEqual(validations, 2)
            }
        }
    }

    func testReplacementNativeBootReceivesNoInputWrites() async throws {
        try await withFixture { fixture in
            try fixture.replaceBoot()
            do {
                try await fixture.client.sendInput(paneID: "phone", bytes: Array("answer\r".utf8),
                    endpointIdentity: fixture.identity)
                XCTFail("A replacement boot must reject all tokens.")
            } catch { XCTAssertEqual(error as? HerdrEndpointError, .staleIdentity) }
            XCTAssertEqual(try fixture.requests().count, 0)
        }
    }

    func testNativeRestartDuringSubmitDelayPreventsEnter() async throws {
        try await withFixture { fixture in
            let pending = Task {
                try await fixture.client.sendInput(paneID: "phone", bytes: Array("answer\r".utf8),
                    endpointIdentity: fixture.identity)
            }
            defer { pending.cancel() }
            try await fixture.waitForRequestCount(1)
            try fixture.replaceBoot()
            do { try await pending.value; XCTFail("A replacement boot must reject Enter.") }
            catch { XCTAssertEqual(error as? HerdrEndpointError, .staleIdentity) }
            XCTAssertEqual(try fixture.requests().count, 1)
        }
    }

    func testCancellationDuringSubmitDelayPreventsRemainingTokens() async throws {
        for native in [false, true] {
            try await withFixture { fixture in
                let pending = Task {
                    try await fixture.client.sendInput(paneID: "phone", bytes: Array("answer\rmore\r".utf8),
                        endpointIdentity: native ? fixture.identity : nil)
                }
                defer { pending.cancel() }
                try await fixture.waitForRequestCount(1)
                pending.cancel()
                do { try await pending.value; XCTFail("Cancellation must stop remaining tokens.") }
                catch { XCTAssertTrue(error is CancellationError) }
                XCTAssertEqual(try fixture.requests().count, 1)
            }
        }
    }

    private func withFixture(_ run: (NotificationInputFixture) async throws -> Void) async throws {
        let fixture = try NotificationInputFixture()
        defer { fixture.stop() }
        try await fixture.waitForSockets()
        try await run(fixture)
    }
}

private actor NotificationInputHost {
    private var connectionID = "original"
    private(set) var validations = 0
    private let action = HostNotificationAction(connectionID: "original", paneID: "phone", operation: .input(bytesBase64: ""))

    func replaceHost() { connectionID = "replacement" }

    func validate() throws {
        validations += 1
        guard action.isAllowed(currentConnectionID: connectionID, remote: false) else {
            throw HerdrEndpointError.staleIdentity
        }
    }
}

private final class NotificationInputFixture: @unchecked Sendable {
    private let root = URL(fileURLWithPath: "/tmp/rai-notification-\(UUID().uuidString.prefix(8))")
    private var processes: [Process] = []
    private var record: URL { root.appendingPathComponent("requests") }
    private var api: URL { root.appendingPathComponent("api.sock") }
    private var endpoint: URL { root.appendingPathComponent("endpoint.sock") }
    var client: HerdrClient { HerdrClient(socketPath: api.path) }
    var identity: (socketPath: String, bootID: String) { (endpoint.path, "boot") }

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        do {
            for (name, socket, mode, log) in [
                ("fake_endpoint_server", endpoint.path, "mutation", record.path),
                ("fake_pinned_rpc", api.path, "mutation_success", record.path + ".api")
            ] {
                let script = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "py", subdirectory: "Fixtures"))
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                process.arguments = [script.path, socket, mode, log]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                processes.append(process)
            }
        } catch { stop(); throw error }
    }

    func requests() throws -> [[String: Any]] {
        let file = record.appendingPathExtension("api")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try String(contentsOf: file).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    func replaceBoot() throws { try Data().write(to: record.appendingPathExtension("replacement")) }

    func waitForSockets() async throws {
        try await waitUntil { [api, endpoint].allSatisfy { FileManager.default.fileExists(atPath: $0.path) } }
    }

    func waitForRequestCount(_ count: Int) async throws {
        try await waitUntil { try requests().count == count }
    }

    private func waitUntil(_ condition: () throws -> Bool) async throws {
        for _ in 0..<300 {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The notification fixture did not reach its expected state.")
        throw HerdrEndpointError.timedOut
    }

    func stop() {
        for process in processes where process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: root)
    }
}
