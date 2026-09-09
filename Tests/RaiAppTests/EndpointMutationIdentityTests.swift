import Foundation
import RaiCore
import XCTest
@testable import RaiApp

@MainActor
final class EndpointMutationIdentityTests: XCTestCase {
    func testMacPromptPinsBootBeforeWritingAndNeverReplays() async throws {
        try await verifyMutation(phoneHost: false, prompt: true)
    }

    func testMacPluginPinsBootBeforeWritingAndNeverReplays() async throws {
        try await verifyMutation(phoneHost: false, prompt: false)
    }

    func testPhoneHostPromptPinsBootBeforeWritingAndNeverReplays() async throws {
        try await verifyMutation(phoneHost: true, prompt: true)
    }

    func testPhoneHostPluginPinsBootBeforeWritingAndNeverReplays() async throws {
        try await verifyMutation(phoneHost: true, prompt: false)
    }

    private func verifyMutation(phoneHost: Bool, prompt: Bool) async throws {
        for mode in ["replacement", "success", "drop"] {
            try await verifyScenario(phoneHost: phoneHost, prompt: prompt, mode: mode)
        }
    }

    private func verifyScenario(phoneHost: Bool, prompt: Bool, mode: String) async throws {
        let fixture = try MutationFixture(mode: mode)
        let model = EndpointWindowModel(socketPath: fixture.api.path)
        var latest: EndpointBridgeState?
        var host: EndpointBridgeHost?
        let identity = EndpointViewIdentity(connectionID: "mutation-test-host")
        func openView() {
            if phoneHost {
                latest = nil
                host = EndpointBridgeHost(identity: identity, socketPath: fixture.api.path, model: model) { state, done in
                    latest = state
                    done()
                }
                host?.handle(.init(identity: identity, sequence: 1, operation: .open(columns: 80, rows: 24)))
            } else { model.start() }
        }
        defer { host?.stop(); model.stop(); fixture.stop() }
        try await waitUntil { fixture.socketsExist }
        openView()
        try await waitUntil { model.surface != nil && !model.busy && (!phoneHost || latest?.surface != nil) }
        XCTAssertNil(model.error, mode)
        XCTAssertEqual(model.snapshot?.bootID, "boot", mode)
        try Data().write(to: fixture.record.appendingPathExtension("mutation_started"))
        if mode == "replacement" { try Data().write(to: fixture.record.appendingPathExtension("replacement")) }

        let text = "single mutation\nUnicode 👩🏽‍💻 é"
        let promptRequest = EndpointTextRequest(bootID: "boot", paneID: "phone", action: .prompt(text))
        let pluginRequest = EndpointPluginRequest(bootID: "boot", operation: .enable("test.plugin"))
        let requestID = prompt ? promptRequest.id : pluginRequest.id
        if let host {
            let operation: EndpointBridgeOperation = prompt ? .terminalAction(promptRequest) : .plugin(pluginRequest)
            host.handle(.init(identity: identity, sequence: 2, bootID: "boot", operation: operation))
        } else {
            XCTAssertTrue(prompt ? model.performTerminalAction(promptRequest) : model.performPlugin(pluginRequest), mode)
        }
        try await waitUntil {
            let id = prompt ? model.terminalResult?.requestID : model.pluginResult?.requestID
            let emittedID = prompt ? latest?.terminalResult?.requestID : latest?.pluginResult?.requestID
            return !model.busy && id == requestID && (!phoneHost || emittedID == requestID)
        }
        let error = prompt ? model.terminalResult?.error : model.pluginResult?.error
        if mode == "success" {
            XCTAssertNil(error)
            if prompt { XCTAssertEqual(model.terminalResult?.text, "Prompt submitted.") }
            else { XCTAssertEqual(model.pluginResult?.value?.objectValue?["type"], .string("ok")) }
        } else {
            XCTAssertNotNil(error, mode)
            if mode == "replacement" { XCTAssertTrue(error?.contains(HerdrEndpointError.staleIdentity.localizedDescription) == true) }
            if mode == "drop", prompt {
                XCTAssertEqual(model.terminalResult?.outcomeUnknown, true)
                XCTAssertTrue(error?.contains("Rai will not retry.") == true)
            }
        }
        let checks = try fixture.jsonLines(".verifications")
        XCTAssertEqual(checks.count, 2, mode)
        XCTAssertEqual(checks.last?["api_connected"] as? Bool, true, mode)
        XCTAssertEqual(checks.last?["boot"] as? String, mode == "replacement" ? "replacement" : "boot")
        if mode == "replacement" {
            try await waitUntil { FileManager.default.fileExists(atPath: fixture.record.path + ".api.closed_without_write") }
        }
        if mode == "drop" {
            host?.stop(); model.stop()
            openView()
            try await waitUntil { model.surface != nil && !model.busy && (!phoneHost || latest?.surface != nil) }
            XCTAssertNil(model.terminalResult)
            XCTAssertNil(model.pluginResult)
        }
        try await Task.sleep(for: .milliseconds(100))
        let requests = try fixture.jsonLines(".api")
        XCTAssertEqual(requests.count, mode == "replacement" ? 0 : 1, mode)
        XCTAssertEqual(try String(contentsOfFile: fixture.record.path + ".api.connections"), "accepted\n", mode)
        if let request = requests.first {
            XCTAssertEqual(request["method"] as? String, prompt ? "agent.prompt" : "plugin.enable")
            let params = try XCTUnwrap(request["params"] as? [String: String])
            XCTAssertEqual(params, prompt ? ["target": "phone", "text": text] : ["plugin_id": "test.plugin"])
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Mutation fixture did not reach its expected state within five seconds")
        throw NSError(domain: "EndpointMutationIdentityTests", code: 1)
    }
}

@MainActor
private final class MutationFixture {
    let root: URL
    let api: URL
    let endpoint: URL
    let record: URL
    private var processes: [Process] = []

    var socketsExist: Bool {
        [api, endpoint].allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }

    init(mode: String) throws {
        root = URL(fileURLWithPath: "/tmp/rai-mutation-\(UUID().uuidString.prefix(8))")
        api = root.appendingPathComponent("herdr.sock")
        endpoint = URL(fileURLWithPath: RemoteConnection.clientSocketPath(for: api.path))
        record = root.appendingPathComponent("requests")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let scripts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("RaiCoreTests/Fixtures")
        do {
            for (name, socket, fixtureMode, log) in [
                ("fake_endpoint_server.py", endpoint.path, "mutation", record.path),
                ("fake_pinned_rpc.py", api.path, "mutation_" + mode, record.path + ".api")
            ] {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                process.arguments = [scripts.appendingPathComponent(name).path, socket, fixtureMode, log]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                processes.append(process)
            }
        } catch { stop(); throw error }
    }

    func jsonLines(_ suffix: String) throws -> [[String: Any]] {
        let path = record.path + suffix
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        return try String(contentsOfFile: path).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    func stop() {
        for process in processes where process.isRunning { process.terminate(); process.waitUntilExit() }
        try? FileManager.default.removeItem(at: root)
    }
}
