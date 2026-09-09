import AppKit
import Foundation
@testable import RaiCore
import XCTest
@testable import RaiApp

@MainActor
final class EndpointPluginLifecycleTests: XCTestCase {
    func testPluginPaneLaunchUsesOnlyTheOwningNativeClientAndRequiresCapability() async throws {
        let install: (EndpointPluginOperation, String, String) async throws -> JSONValue = { _, _, _ in
            XCTFail("Pane launch must not invoke a host installer")
            return .null
        }
        try await withEndpoint(mode: "plugin_pane", install: install) { owner, _ in
            try await withEndpoint(install: install) { other, _ in
                let plugin = try XCTUnwrap(EndpointInstalledPlugin(.object(["plugin_id": .string("test.plugin"),
                    "name": .string("Test"), "enabled": .bool(true), "panes": .array([
                        .object(["id": .string("popup"), "title": .string("Popup")])])])))
                let invocation = try XCTUnwrap(EndpointPluginPaneInvocation(plugin: plugin,
                    pane: try XCTUnwrap(plugin.panes.first), snapshot: try XCTUnwrap(owner.snapshot)))
                let request = EndpointPluginRequest(bootID: "boot", operation: .openPane(invocation))
                XCTAssertFalse(other.performPlugin(request), "Unadvertised methods must send no request.")
                XCTAssertTrue(owner.performPlugin(request))
                for _ in 0..<200 {
                    if owner.pluginResult?.requestID == request.id { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertEqual(owner.pluginResult?.requestID, request.id)
                XCTAssertNil(owner.pluginResult?.error)
                let record = URL(fileURLWithPath: owner.apiSocketPath).deletingLastPathComponent().appendingPathComponent("requests.plugin")
                let lines = try String(contentsOf: record, encoding: .utf8).split(separator: "\n")
                XCTAssertEqual(lines.count, 1)
                let sent = try JSONDecoder().decode(JSONValue.self, from: Data(try XCTUnwrap(lines.first).utf8))
                XCTAssertEqual(sent.objectValue?["method"], .string("plugin.pane.open"))
                XCTAssertEqual(sent.objectValue?["params"], .object(["plugin_id": .string("test.plugin"),
                    "entrypoint": .string("popup"), "focus": .bool(true)]))
                XCTAssertFalse(FileManager.default.fileExists(atPath: other.apiSocketPath), "No generic API fixture exists.")
                XCTAssertNil(other.pluginResult)
            }
        }
    }

    func testNativeAndPhoneIntegrationInstallationRejectsUnisolatedPaths() async throws {
        let paths = AppDataPaths(environment: ["RAI_DATA_ROOT": "/tmp/rai-integration-isolation-test"])
        try await withEndpoint(dataPaths: paths, install: { _, _, _ in
            XCTFail("Integration rejection must not invoke the plugin installer")
            return .null
        }) { model, _ in
            let record = URL(fileURLWithPath: model.apiSocketPath).deletingLastPathComponent().appendingPathComponent("requests")
            let before = try Data(contentsOf: record)
            let direct = EndpointPluginRequest(bootID: "boot", operation: .installIntegration("droid"))
            XCTAssertTrue(model.performPlugin(direct))
            XCTAssertEqual(model.pluginResult?.requestID, direct.id)
            XCTAssertTrue(model.pluginResult?.error?.contains("disposable test account") == true)
            XCTAssertFalse(model.busy)

            let identity = EndpointViewIdentity(connectionID: "isolated-phone")
            var states: [EndpointBridgeState] = []
            let host = EndpointBridgeHost(identity: identity, socketPath: model.apiSocketPath, model: model) { state, done in
                states.append(state); done()
            }
            defer { host.stop() }
            let phone = EndpointPluginRequest(bootID: "boot", operation: .installIntegration("future-agent"))
            host.handle(.init(identity: identity, sequence: 1, bootID: "boot", operation: .plugin(phone)))
            for _ in 0..<100 {
                if states.last?.pluginResult?.requestID == phone.id { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(states.last?.pluginResult?.requestID, phone.id)
            XCTAssertTrue(states.last?.pluginResult?.error?.contains("disposable test account") == true)
            XCTAssertEqual(states.last?.snapshot?.bootID, "boot")
            XCTAssertNil(states.last?.error)
            XCTAssertFalse(model.busy)
            XCTAssertEqual(try Data(contentsOf: record), before, "Rejected installs must send no native request")
        }
    }

    func testCancelledLocalFetchCannotCreateAPreviewAndRemovesItsCheckout() async throws {
        _ = NSApplication.shared
        let started = expectation(description: "fetch started")
        var continuation: CheckedContinuation<RaiModel.HerdrCommandResult, Never>?
        var checkout: String?
        var commands: [[String]] = []
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "rai-plugin-test-\(UUID().uuidString)"))
        let model = RaiModel(userDefaults: defaults, pluginPreviewRunner: { _, arguments in
            commands.append(arguments)
            if arguments.first == "init" { checkout = arguments.last }
            if arguments.contains("fetch") {
                started.fulfill()
                return await withCheckedContinuation { continuation = $0 }
            }
            return .init(succeeded: true, standardOutput: "", standardError: "")
        })
        let operation = Task { await model.preparePluginInstall(source: "owner/repo", reference: "") }
        await fulfillment(of: [started], timeout: 2)
        operation.cancel()
        continuation?.resume(returning: .init(succeeded: true, standardOutput: "", standardError: ""))
        let preview = await operation.value
        XCTAssertFalse(preview.canConfirm)
        XCTAssertFalse(commands.contains { $0.contains("rev-parse") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(checkout)))
    }

    func testNamedLocalSessionInstallKeepsItsSocketAndConfig() async throws {
        _ = NSApplication.shared
        let selectedSocket = "/tmp/rai-named-session/herdr.sock"
        var boot = "selected-boot"
        var verifiedSockets: [String] = []
        var installs: [([String], [String: String])] = []
        var checkout: String?
        let model = RaiModel(client: HerdrClient(socketPath: "/tmp/rai-other-session/herdr.sock"),
                             userDefaults: try XCTUnwrap(UserDefaults(suiteName: "rai-plugin-test-\(UUID())")),
                             pluginPreviewRunner: { _, arguments in
            if arguments.first == "init" { checkout = arguments.last }
            if arguments.contains("checkout"), let checkout {
                do { try "id = 'test.plugin'".write(toFile: checkout + "/herdr-plugin.toml", atomically: true, encoding: .utf8) }
                catch { return .init(succeeded: false, standardOutput: "", standardError: error.localizedDescription) }
            }
            return .init(succeeded: true, standardOutput: arguments.contains("rev-parse") ? String(repeating: "a", count: 40) : "",
                         standardError: "")
        }, pluginInstallRunner: { arguments, environment in
            installs.append((arguments, environment))
            return .init(succeeded: true, standardOutput: "installed", standardError: "")
        }, pluginBootReader: { socket in
            verifiedSockets.append(socket)
            return boot
        })
        let prepared = try await model.endpointPluginInstall(.prepareInstall(source: "owner/repo", reference: ""),
                                                              socketPath: selectedSocket, bootID: boot)
        XCTAssertEqual(prepared.objectValue?["can_confirm"], .bool(true))
        let id = try XCTUnwrap(prepared.objectValue?["preview_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        do {
            _ = try await model.endpointPluginInstall(.confirmInstall(id), socketPath: "/tmp/wrong.sock", bootID: boot)
            XCTFail("A different endpoint must not confirm this preview")
        } catch {}
        boot = "replacement-boot"
        do {
            _ = try await model.endpointPluginInstall(.confirmInstall(id), socketPath: selectedSocket, bootID: "selected-boot")
            XCTFail("A replaced endpoint must reject confirmation")
        } catch {}
        XCTAssertTrue(installs.isEmpty)
        boot = "selected-boot"
        let result = try await model.endpointPluginInstall(.confirmInstall(id), socketPath: selectedSocket, bootID: boot)
        XCTAssertEqual(result.objectValue?["output"], .string("installed"))
        XCTAssertEqual(installs.count, 1)
        XCTAssertEqual(installs.first?.0, ["plugin", "install", "owner/repo", "--ref", String(repeating: "a", count: 40), "--yes"])
        XCTAssertEqual(installs.first?.1["HERDR_SOCKET_PATH"], selectedSocket)
        XCTAssertEqual(installs.first?.1["HERDR_CONFIG_PATH"], AppDataPaths.current.herdrConfigFile.path)
        XCTAssertEqual(verifiedSockets.last, selectedSocket)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(checkout)))
    }

    func testNamedLocalSessionUninstallKeepsItsSocket() async throws {
        _ = NSApplication.shared
        var command: [String] = []
        var selectedSocket: String?
        let model = RaiModel(client: HerdrClient(socketPath: "/tmp/other.sock"),
                             userDefaults: try XCTUnwrap(UserDefaults(suiteName: "rai-plugin-test-\(UUID())")),
                             pluginInstallRunner: { arguments, environment in
            command = arguments; selectedSocket = environment["HERDR_SOCKET_PATH"]
            return .init(succeeded: true, standardOutput: "", standardError: "")
        }, pluginBootReader: { _ in "boot" })
        _ = try await model.endpointPluginInstall(.uninstall("test.plugin"), socketPath: "/tmp/selected.sock", bootID: "boot")
        XCTAssertEqual(command, ["plugin", "uninstall", "test.plugin"])
        XCTAssertEqual(selectedSocket, "/tmp/selected.sock")
    }

    func testCancellingAnActiveReviewRejectsLateApproval() async throws {
        let started = expectation(description: "review started")
        var continuation: CheckedContinuation<JSONValue, Never>?
        var cancelled: [UUID] = []
        let previewID = UUID()
        try await withEndpoint(install: { operation, _, _ in
            if case .prepareInstall = operation {
                started.fulfill()
                return await withCheckedContinuation { continuation = $0 }
            }
            if case .cancelInstall(let id) = operation { cancelled.append(id) }
            return .object([:])
        }) { model, _ in
            let prepare = EndpointPluginRequest(bootID: "boot", operation: .prepareInstall(source: "owner/repo", reference: ""))
            XCTAssertTrue(model.performPlugin(prepare))
            await self.fulfillment(of: [started], timeout: 2)
            XCTAssertTrue(model.busy)
            let cancel = EndpointPluginRequest(bootID: "boot", operation: .cancelInstall(prepare.id))
            XCTAssertTrue(model.performPlugin(cancel))
            XCTAssertFalse(model.busy)
            continuation?.resume(returning: .object(["preview_id": .string(previewID.uuidString), "can_confirm": .bool(true)]))
            for _ in 0..<30 { await Task.yield() }
            XCTAssertEqual(model.pluginResult?.requestID, cancel.id)
            XCTAssertTrue(cancelled.contains(prepare.id))
            XCTAssertTrue(cancelled.contains(previewID))
            XCTAssertFalse(model.performPlugin(.init(bootID: "boot", operation: .confirmInstall(previewID))))
        }
    }

    func testDisconnectedEndpointRejectsAnExistingInstallApproval() async throws {
        let previewID = UUID()
        var confirmations = 0
        try await withEndpoint(install: { operation, _, _ in
            if case .confirmInstall = operation { confirmations += 1 }
            return .object(["preview_id": .string(previewID.uuidString), "can_confirm": .bool(true)])
        }) { model, process in
            XCTAssertTrue(model.performPlugin(.init(bootID: "boot", operation: .prepareInstall(source: "owner/repo", reference: ""))))
            for _ in 0..<100 {
                if model.pluginResult != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNotNil(model.pluginResult)
            process.terminate()
            for _ in 0..<100 {
                if model.error != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNotNil(model.error)
            XCTAssertNotNil(model.snapshot)
            XCTAssertFalse(model.performPlugin(.init(bootID: "boot", operation: .confirmInstall(previewID))))
            XCTAssertEqual(confirmations, 0)
        }
    }

    func testClosingAReadyReviewDoesNotCancelAnotherEndpointAction() async throws {
        let previewID = UUID()
        try await withEndpoint(install: { _, _, _ in
            .object(["preview_id": .string(previewID.uuidString), "can_confirm": .bool(true)])
        }) { model, _ in
            XCTAssertTrue(model.performPlugin(.init(bootID: "boot", operation: .prepareInstall(source: "owner/repo", reference: ""))))
            for _ in 0..<100 {
                if model.pluginResult != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            model.perform("client_shell.surface.set", params: ["active": .bool(true)])
            XCTAssertTrue(model.busy)
            XCTAssertTrue(model.performPlugin(.init(bootID: "boot", operation: .cancelInstall(previewID))))
            XCTAssertTrue(model.busy, "Closing the review must leave the later action running")
        }
    }

    func testPhonePluginRejectionReturnsRequestErrorWithoutClosingView() async throws {
        var priorResult: CheckedContinuation<JSONValue, Never>?
        try await withEndpoint(install: { operation, _, _ in
            if case .prepareInstall = operation { return await withCheckedContinuation { priorResult = $0 } }
            return .object([:])
        }) { model, _ in
            let identity = EndpointViewIdentity(connectionID: "test")
            var states: [EndpointBridgeState] = []
            let host = EndpointBridgeHost(identity: identity, socketPath: model.apiSocketPath, model: model) { state, done in
                states.append(state); done()
            }
            defer { host.stop() }
            let stale = EndpointPluginRequest(bootID: "boot", operation: .confirmInstall(UUID()))
            host.handle(.init(identity: identity, sequence: 1, bootID: "boot", operation: .plugin(stale)))
            for _ in 0..<100 {
                if states.last?.pluginResult?.requestID == stale.id { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(states.last?.pluginResult?.error, HerdrEndpointError.staleIdentity.localizedDescription)
            XCTAssertNil(states.last?.error)
            XCTAssertEqual(states.last?.sequence, 1)
            XCTAssertTrue(model.performPlugin(.init(bootID: "boot", operation: .prepareInstall(source: "owner/repo", reference: ""))))
            for _ in 0..<100 {
                if priorResult != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(model.busy)
            let busy = EndpointPluginRequest(bootID: "boot", operation: .list)
            host.handle(.init(identity: identity, sequence: 2, bootID: "boot", operation: .plugin(busy)))
            priorResult?.resume(returning: .object(["can_confirm": .bool(false)]))
            for _ in 0..<100 {
                if states.last?.pluginResult?.requestID == busy.id { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(states.last?.pluginResult?.error, HerdrEndpointError.busy.localizedDescription)
            XCTAssertNil(states.last?.error)
            XCTAssertEqual(states.last?.sequence, 2)
        }
    }

    func testLegacyPhoneClosureRejectsMissingAndStaleConnectionIdentity() async throws {
        _ = NSApplication.shared
        let model = RaiModel(userDefaults: try XCTUnwrap(UserDefaults(suiteName: "rai-close-identity-\(UUID())")))
        for connectionID in [nil, "old-resource"] as [String?] {
            do {
                try await model.closeWorkspaceFromBridge(workspaceID: "w1", connectionID: connectionID)
                XCTFail("Closure must carry the reviewed resource generation")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("session_changed"))
            }
        }
    }

    func testFastCommittedTextKeepsConnectionAndDeliversEveryCharacter() async throws {
        try await withEndpoint(mode: "input_record", install: { _, _, _ in .null }) { model, process in
            for _ in 0..<100 where !model.acceptsInput { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(model.acceptsInput)
            let text = String(repeating: "aßג", count: 200)
            for character in text { model.send(.text(String(character))) }
            XCTAssertNil(model.error, "A keyboard burst must not disconnect the endpoint")
            let record = try XCTUnwrap(process.arguments?.last)
            var received = ""
            for _ in 0..<200 {
                received = try String(contentsOfFile: record).split(separator: "\n").reduce(into: "") { result, line in
                    let digits = Array(line)
                    guard digits.count.isMultiple(of: 2) else { return }
                    let bytes = stride(from: 0, to: digits.count, by: 2).compactMap {
                        UInt8(String(digits[$0...($0 + 1)]), radix: 16)
                    }
                    var reader = EndpointBinaryReader(data: Data(bytes))
                    guard (try? reader.integer()) == 13 else { return }
                    _ = try reader.string()
                    XCTAssertEqual(try reader.integer(), 1)
                    XCTAssertEqual(try reader.integer(), 1)
                    result += try reader.string()
                }
                if received == text { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(received, text)
            XCTAssertNil(model.error)
        }
    }

    func testCommittedTextKeepsKeyAndPasteBoundaries() async throws {
        try await withEndpoint(mode: "input_record", install: { _, _, _ in .null }) { model, process in
            for _ in 0..<100 where !model.acceptsInput { try await Task.sleep(for: .milliseconds(10)) }
            let prefix = String(repeating: "a", count: 200)
            let suffix = String(repeating: "ב", count: 200)
            for character in prefix { model.send(.text(String(character))) }
            model.send(.key(.init(code: .special(.enter))))
            model.send(.paste("literal\npaste"))
            for character in suffix { model.send(.text(String(character))) }
            let inputs: [EndpointInput] = [.text(prefix), .key(.init(code: .special(.enter))),
                                           .paste("literal\npaste"), .text(suffix)]
            let expected = inputs.map { input in
                var frame = Data([13])
                HerdrEndpointWire.appendString("phone", to: &frame)
                frame.append(1)
                input.encode(to: &frame)
                return frame.map { String(format: "%02x", $0) }.joined()
            }
            let record = try XCTUnwrap(process.arguments?.last)
            var received: [String] = []
            for _ in 0..<200 {
                received = try String(contentsOfFile: record).split(separator: "\n")
                    .map(String.init).filter { $0.hasPrefix("0d") }
                if received.count >= expected.count { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(received, expected)
            XCTAssertNil(model.error)
        }
    }

    func testStoppingTheEndpointClearsItsTitle() async throws {
        try await withEndpoint(mode: "window_title", install: { _, _, _ in .object([:]) }) { model, _ in
            for _ in 0..<100 {
                if model.windowTitle != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(model.windowTitle, "Rai scoped title")
            model.stop()
            XCTAssertNil(model.windowTitle)
        }
    }

    private func withEndpoint(mode: String = "surface", dataPaths: AppDataPaths = .current,
                              install: @escaping (EndpointPluginOperation, String, String) async throws -> JSONValue,
                              run: (EndpointWindowModel, Process) async throws -> Void) async throws {
        let root = URL(fileURLWithPath: "/tmp/rai-plugin-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let socket = root.appendingPathComponent("test.sock").path
        let clientSocket = RemoteConnection.clientSocketPath(for: socket)
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("RaiCoreTests/Fixtures/fake_endpoint_server.py")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, clientSocket, mode, root.appendingPathComponent("requests").path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let model = EndpointWindowModel(socketPath: socket, installPlugin: install, dataPaths: dataPaths)
        defer {
            model.stop()
            if process.isRunning { process.terminate() }
            try? FileManager.default.removeItem(at: root)
        }
        try process.run()
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: clientSocket) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        model.start()
        for _ in 0..<200 {
            if model.snapshot != nil, !model.busy { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(model.snapshot)
        XCTAssertNil(model.error)
        XCTAssertFalse(model.busy)
        try await run(model, process)
    }
}
