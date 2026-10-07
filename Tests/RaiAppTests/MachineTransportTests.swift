import Foundation
import RaiCore
import XCTest
@testable import RaiApp

@MainActor
final class MachineTransportTests: XCTestCase {
    func testEmptySSHInstanceCreatesExactlyOneSpacePerRequest() async throws {
        guard let root = ProcessInfo.processInfo.environment["RAI_MACHINE_E2E_ROOT"],
              let target = ProcessInfo.processInfo.environment["RAI_EMPTY_MACHINE_E2E_TARGET"],
              AppDataPaths.current.isolatedRoot?.resolvingSymlinksInPath().path
                == URL(fileURLWithPath: root).resolvingSymlinksInPath().path else {
            throw XCTSkip("Requires an owned empty SSH fixture and RAI_EMPTY_MACHINE_E2E_TARGET.")
        }
        let fixture = try XCTUnwrap(LabSSHConfiguration.load(root: URL(fileURLWithPath: root)))
        try fixture.validate(target: target)
        let directory = MachineDirectory()
        defer { directory.stop() }
        try await directory.refreshCatalogOnly()
        let entry = try XCTUnwrap(directory.state.entries.first { $0.target == target })
        let remote = try await RemoteConnection.discoverSocket(target: target, sessionName: entry.endpoint.session)
        let tunnel = RemoteConnection(target: target, sessionName: remote.sessionName, remoteSocketPath: remote.socketPath)
        try await tunnel.start()
        defer { tunnel.stop() }
        let api = HerdrClient(socketPath: tunnel.localSocketPath)
        defer { api.disconnect() }
        let before = try await api.snapshot()
        guard before.workspaces.isEmpty else {
            XCTFail("The dedicated creation fixture must start empty.")
            return
        }

        let first = try await directory.createWorkspace(on: entry.endpoint)
        // Match the app ordering: create first, then connect the display.
        try await directory.ensureConnected(entry.endpoint)
        let afterFirst = try await api.snapshot()
        XCTAssertEqual(afterFirst.workspaces.map(\.workspaceID), [first])
        XCTAssertEqual(afterFirst.tabs.count, 1)
        XCTAssertEqual(afterFirst.panes.count, 1)

        let second = try await directory.createWorkspace(on: entry.endpoint)
        try await directory.ensureConnected(entry.endpoint)
        let afterSecond = try await api.snapshot()
        XCTAssertEqual(afterSecond.workspaces.map(\.workspaceID), [first, second])
        XCTAssertEqual(afterSecond.tabs.count, 2)
        XCTAssertEqual(afterSecond.panes.count, 2)
        XCTAssertEqual(afterSecond.panes.first?.terminalID, afterFirst.panes.first?.terminalID)

        let model = EndpointWindowModel(socketPath: tunnel.localSocketPath)
        defer { model.stop() }
        model.start()
        for _ in 0..<100 where model.busy || model.snapshot == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(model.error)
        try await api.closeWorkspace(second)
        for _ in 0..<100 where directory.workspaces.count != 1 {
            try await Task.sleep(for: .milliseconds(50))
        }
        let last = try XCTUnwrap(directory.workspaces.first)
        try await model.setSurfaceActive(false)
        try await directory.close(InstanceCloseRequest(workspace: last, tabID: nil))
        // Allow queued title refreshes and server maintenance to run.
        try await Task.sleep(for: .seconds(5))
        let afterClose = try await api.snapshot()
        XCTAssertTrue(afterClose.workspaces.isEmpty)
        model.stop()

        let third = try await directory.createWorkspace(on: entry.endpoint)
        try await directory.ensureConnected(entry.endpoint)
        let afterRecreate = try await api.snapshot()
        XCTAssertEqual(afterRecreate.workspaces.map(\.workspaceID), [third])
        XCTAssertEqual(afterRecreate.tabs.count, 1)
        directory.stop()
        try await api.closeWorkspace(third)
        try JSONEncoder().encode(afterSecond).write(
            to: URL(fileURLWithPath: root).appendingPathComponent("workspace-creation-check.json"))
    }

    func testIsolatedSSHConnectionsKeepDuplicateResourcesSeparateAndRejectOldConnections() async throws {
        guard let root = ProcessInfo.processInfo.environment["RAI_MACHINE_E2E_ROOT"],
              AppDataPaths.current.isolatedRoot?.resolvingSymlinksInPath().path
                == URL(fileURLWithPath: root).resolvingSymlinksInPath().path else {
            throw XCTSkip("Requires the owned disposable SSH fixture and explicit RAI_MACHINE_E2E_ROOT.")
        }
        _ = try XCTUnwrap(LabSSHConfiguration.load(root: URL(fileURLWithPath: root)))
        let directory = MachineDirectory()
        defer { directory.stop() }
        await directory.perform(.init(revision: directory.state.revision, operation: .refresh))
        try await waitForMachines(directory)
        let first = try XCTUnwrap(directory.state.entries.first { $0.target == "rai-lab-1" })
        let second = try XCTUnwrap(directory.state.entries.first { $0.target == "rai-lab-2" })
        let firstID = try XCTUnwrap(first.connectionID), secondID = try XCTUnwrap(second.connectionID)
        let firstPath = try XCTUnwrap(directory.resolve(first.endpoint, connectionID: firstID))
        let secondPath = try XCTUnwrap(directory.resolve(second.endpoint, connectionID: secondID))
        XCTAssertNotEqual(firstPath, secondPath)
        XCTAssertNotEqual(firstID, secondID)
        let firstView = HerdrEndpointConnection(), secondView = HerdrEndpointConnection()
        defer { firstView.disconnect(); secondView.disconnect() }
        let firstSnapshot = try await firstView.connect(socketPath: RemoteConnection.clientSocketPath(for: firstPath))
        let secondSnapshot = try await secondView.connect(socketPath: RemoteConnection.clientSocketPath(for: secondPath))
        XCTAssertNotEqual(firstSnapshot.bootID, secondSnapshot.bootID)
        XCTAssertTrue(firstSnapshot.panes.contains { $0.objectValue?["pane_id"]?.stringValue == "w1:p1" })
        XCTAssertTrue(secondSnapshot.panes.contains { $0.objectValue?["pane_id"]?.stringValue == "w1:p1" })
        _ = try await firstView.request(method: "client_shell.surface.set", params: ["active": .bool(true)], expectedBootID: firstSnapshot.bootID)
        let original = try XCTUnwrap(firstSnapshot.workspaces.first { $0.objectValue?["workspace_id"]?.stringValue == "w1" }?.objectValue?["label"]?.stringValue)
        let secondAPI = HerdrClient(socketPath: secondPath)
        defer { secondAPI.disconnect() }
        let before = try await secondAPI.snapshot()
        _ = try await firstView.request(method: "workspace.rename", params: ["workspace_id": .string("w1"), "label": .string("Machine routing verified")], expectedBootID: firstSnapshot.bootID)
        let after = try await secondAPI.snapshot()
        XCTAssertEqual(before.workspaces, after.workspaces, "A duplicate resource ID on another machine must remain unchanged.")
        do {
            _ = try await firstView.request(method: "workspace.rename", params: ["workspace_id": .string("w1"), "label": .string("Must not run")], expectedBootID: secondSnapshot.bootID)
            XCTFail("A different machine boot identity must fail.")
        } catch { XCTAssertEqual(error as? HerdrEndpointError, .staleIdentity) }
        _ = try await firstView.request(method: "workspace.rename", params: ["workspace_id": .string("w1"), "label": .string(original)], expectedBootID: firstSnapshot.bootID)
        let firstAgent = try XCTUnwrap(first.agents.first { $0.resource.paneID == "w1:p1" })
        let secondAgent = try XCTUnwrap(second.agents.first { $0.resource.paneID == "w1:p1" })
        XCTAssertNotEqual(firstAgent.id, secondAgent.id)
        let firstAPI = HerdrClient(socketPath: firstPath)
        defer { firstAPI.disconnect() }
        let firstBeforeSelection = try await firstAPI.snapshot()
        let model = EndpointWindowModel(socketPath: firstPath)
        defer { model.stop() }
        model.selectAgent(secondAgent, directory: directory)
        for _ in 0..<100 where !model.acceptsInput && model.error == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(model.error, "Agent selection must activate its surface before focusing the pane.")
        XCTAssertTrue(model.acceptsInput)
        XCTAssertEqual(model.machineEndpoint, second.endpoint)
        XCTAssertEqual(model.snapshot?.bootID, secondAgent.resource.bootID)
        XCTAssertEqual(model.snapshot?.focusedPaneID, secondAgent.resource.paneID)
        let firstAfterSelection = try await firstAPI.snapshot()
        XCTAssertEqual(firstBeforeSelection.workspaces, firstAfterSelection.workspaces)
        XCTAssertEqual(firstBeforeSelection.panes, firstAfterSelection.panes)
        model.stop()
        await directory.perform(.init(revision: directory.state.revision, operation: .reconnect(first.endpoint)))
        XCTAssertNil(directory.resolve(first.endpoint, connectionID: firstID))
        try await waitForMachines(directory)
        XCTAssertNotEqual(directory.state.entry(for: first.endpoint)?.connectionID, firstID)
        XCTAssertEqual(directory.state.entry(for: second.endpoint)?.connectionID, secondID)
        let data = try JSONEncoder().encode(directory.state)
        try data.write(to: URL(fileURLWithPath: root).appendingPathComponent("machines-transport-state.json"), options: .atomic)
    }

    func testNewWorkspaceRoutesToTheChosenMachine() async throws {
        guard let root = ProcessInfo.processInfo.environment["RAI_MACHINE_E2E_ROOT"],
              AppDataPaths.current.isolatedRoot?.resolvingSymlinksInPath().path
                == URL(fileURLWithPath: root).resolvingSymlinksInPath().path else {
            throw XCTSkip("Requires the owned SSH fixture and explicit RAI_MACHINE_E2E_ROOT.")
        }
        let directory = MachineDirectory()
        defer { directory.stop() }
        await directory.perform(.init(revision: directory.state.revision, operation: .refresh))
        try await waitForMachines(directory)

        let first = try XCTUnwrap(directory.state.entries.first { $0.target == "rai-lab-1" })
        let second = try XCTUnwrap(directory.state.entries.first { $0.target == "rai-lab-2" })
        let firstID = try XCTUnwrap(first.connectionID)
        let firstPath = try XCTUnwrap(directory.resolve(first.endpoint, connectionID: firstID))
        let secondID = try XCTUnwrap(second.connectionID)
        let secondPath = try XCTUnwrap(directory.resolve(second.endpoint, connectionID: secondID))
        let firstAPI = HerdrClient(socketPath: firstPath)
        let secondAPI = HerdrClient(socketPath: secondPath)
        defer { firstAPI.disconnect(); secondAPI.disconnect() }

        let firstBefore = try await firstAPI.snapshot()
        let secondBefore = try await secondAPI.snapshot()
        try await directory.createWorkspace(on: first.endpoint)

        var firstAfter = firstBefore
        for _ in 0..<100 {
            firstAfter = try await firstAPI.snapshot()
            if firstAfter.workspaces.count > firstBefore.workspaces.count { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(firstAfter.workspaces.count, firstBefore.workspaces.count + 1)
        let secondAfter = try await secondAPI.snapshot()
        XCTAssertEqual(secondAfter.workspaces, secondBefore.workspaces)

        if let created = firstAfter.workspaces.last?.workspaceID {
            try await firstAPI.closeWorkspace(created)
        }

        try await directory.createWorkspace(on: second.endpoint)
        var secondCreated = secondBefore
        for _ in 0..<100 {
            secondCreated = try await secondAPI.snapshot()
            if secondCreated.workspaces.count > secondBefore.workspaces.count { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(secondCreated.workspaces.count, secondBefore.workspaces.count + 1)
        let firstAfterSecondCreate = try await firstAPI.snapshot()
        XCTAssertEqual(firstAfterSecondCreate.workspaces, firstBefore.workspaces)

        if let created = secondCreated.workspaces.last?.workspaceID {
            try await secondAPI.closeWorkspace(created)
        }
    }

    func testAgentLaunchUsesSelectedRemoteShellWithoutTouchingTheSecondMachine() async throws {
        guard let root = ProcessInfo.processInfo.environment["RAI_MACHINE_E2E_ROOT"],
              AppDataPaths.current.isolatedRoot?.resolvingSymlinksInPath().path
                == URL(fileURLWithPath: root).resolvingSymlinksInPath().path else {
            throw XCTSkip("Requires the disposable SSH recorder fixture and complete lab environment.")
        }
        let directory = MachineDirectory()
        defer { directory.stop() }
        await directory.perform(.init(revision: directory.state.revision, operation: .refresh))
        try await waitForMachines(directory)
        let first = try XCTUnwrap(directory.state.entries.first { $0.target == "rai-lab-1" })
        let second = try XCTUnwrap(directory.state.entries.first { $0.target == "rai-lab-2" })
        let firstID = try XCTUnwrap(first.connectionID)
        let path = try XCTUnwrap(directory.resolve(first.endpoint, connectionID: firstID))
        let secondPath = try XCTUnwrap(directory.resolve(second.endpoint, connectionID: try XCTUnwrap(second.connectionID)))
        let secondAPI = HerdrClient(socketPath: secondPath)
        defer { secondAPI.disconnect() }
        let before = try await secondAPI.snapshot()
        let ssh = try RemoteConnection.sshConfigurationArguments(target: "rai-lab-1") + ["-o", "BatchMode=yes", "rai-lab-1"]
        let split = try await MachineCommandRunner.capture(binary: "/usr/bin/ssh",
            arguments: ssh + ["herdr", "pane", "split", "w2:p1", "--direction", "right", "--no-focus"], timeout: 5)
        let splitReply = try JSONDecoder().decode(JSONValue.self, from: split.standardOutput)
        let launchPane = try XCTUnwrap(splitReply.objectValue?["result"]?.objectValue?["pane"]?.objectValue?["pane_id"]?.stringValue)
        addTeardownBlock {
            _ = try await MachineCommandRunner.capture(binary: "/usr/bin/ssh",
                arguments: ssh + ["herdr", "pane", "close", launchPane], timeout: 5)
        }
        let recorderArgs = ssh + ["cat", "/tmp/rai-agent-launch-record.txt"]
        let previousRecord = try await MachineCommandRunner.capture(binary: "/usr/bin/ssh", arguments: recorderArgs, timeout: 5)
        let model = EndpointWindowModel(socketPath: path, machineEndpoint: first.endpoint, machineConnectionID: firstID)
        defer { model.stop() }
        model.start()
        for _ in 0..<100 where model.snapshot == nil || model.busy { try await Task.sleep(for: .milliseconds(50)) }
        let snapshot = try XCTUnwrap(model.snapshot)
        let request = EndpointAgentLaunchRequest(bootID: snapshot.bootID, owningViewID: model.generation,
            paneID: launchPane, name: "rai-fixture-" + UUID().uuidString.prefix(8).lowercased(), kind: .codex)
        XCTAssertFalse(model.launchAgent(.init(bootID: snapshot.bootID, owningViewID: UUID(), paneID: "w2:p1", name: "stale", kind: .codex)))
        XCTAssertTrue(model.launchAgent(request))
        for _ in 0..<300 where model.agentLaunchResult == nil { try await Task.sleep(for: .milliseconds(50)) }
        let result = try XCTUnwrap(model.agentLaunchResult)
        XCTAssertTrue(result.succeeded, result.message)
        let after = try await secondAPI.snapshot()
        XCTAssertEqual(before.panes, after.panes)
        XCTAssertEqual(before.workspaces, after.workspaces)
        let args = recorderArgs
        var recorded = ""
        for _ in 0..<40 {
            let output = try await MachineCommandRunner.capture(binary: "/usr/bin/ssh", arguments: args, timeout: 5)
            recorded = String(decoding: output.standardOutput, as: UTF8.self)
            if recorded.utf8.count > previousRecord.standardOutput.count { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(recorded.utf8.count, previousRecord.standardOutput.count)
        XCTAssertTrue(recorded.contains("RAI_AGENT_LAUNCH_FIXTURE labone /usr/local/bin/codex"))
        try JSONEncoder().encode(result).write(to: URL(fileURLWithPath: root).appendingPathComponent("machines-agent-launch-result.json"))
    }

    func testLegacyRemoteViewsOwnTheirTunnelsAndKeepPluginCommandsRemote() async throws {
        guard let root = ProcessInfo.processInfo.environment["RAI_MACHINE_E2E_ROOT"],
              AppDataPaths.current.isolatedRoot?.resolvingSymlinksInPath().path
                == URL(fileURLWithPath: root).resolvingSymlinksInPath().path else {
            throw XCTSkip("Requires the owned SSH fixture and explicit RAI_MACHINE_E2E_ROOT.")
        }
        _ = try XCTUnwrap(LabSSHConfiguration.load(root: URL(fileURLWithPath: root)))
        let discovered = try await RemoteConnection.discoverSocket(target: "rai-lab-1", sessionName: "rai-remote-one")
        let main = RemoteConnection(target: discovered.target, sessionName: discovered.sessionName, remoteSocketPath: discovered.socketPath)
        defer { main.stop() }
        try await main.start()
        var localCommands = 0
        let mac = EndpointWindowModel(socketPath: main.localSocketPath, remoteContext: main.context,
            installPlugin: { _, _, _ in localCommands += 1; return .null })
        let phone = EndpointWindowModel(socketPath: main.localSocketPath, remoteContext: main.context,
            installPlugin: { _, _, _ in localCommands += 1; return .null })
        let identity = EndpointViewIdentity(connectionID: "legacy-main-remote")
        var phoneState: EndpointBridgeState?
        let host = EndpointBridgeHost(identity: identity, socketPath: main.localSocketPath, model: phone) { state, done in
            phoneState = state; done()
        }
        defer { mac.stop(); host.stop() }
        mac.start()
        host.handle(.init(identity: identity, sequence: 1, operation: .open(columns: 80, rows: 24)))
        for _ in 0..<300 where mac.snapshot == nil || mac.busy || phoneState?.snapshot == nil || phoneState?.busy != false {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(mac.error)
        XCTAssertNil(phoneState?.error)
        let boot = try XCTUnwrap(mac.snapshot?.bootID)
        XCTAssertEqual(phoneState?.snapshot?.bootID, boot)
        XCTAssertTrue(host.ownsRetainedConnection(identity))
        XCTAssertEqual(phoneState?.retainsHostConnection, true)
        XCTAssertNil(mac.machineEndpoint)
        XCTAssertNil(phone.machineEndpoint)
        XCTAssertNotEqual(mac.apiSocketPath, main.localSocketPath)
        XCTAssertNotEqual(phone.apiSocketPath, main.localSocketPath)
        XCTAssertNotEqual(mac.apiSocketPath, phone.apiSocketPath)
        main.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: main.localSocketPath))
        for model in [mac, phone] {
            let api = HerdrClient(socketPath: model.apiSocketPath)
            _ = try await api.snapshot()
            api.disconnect()
            let missing = "rai.e2e.missing." + UUID().uuidString.lowercased()
            XCTAssertTrue(model.performPlugin(.init(bootID: boot, operation: .uninstall(missing))))
            for _ in 0..<300 where model.pluginResult == nil { try await Task.sleep(for: .milliseconds(50)) }
            XCTAssertTrue(model.pluginResult?.error?.contains("Remote plugin command exited") == true,
                model.pluginResult?.error ?? "Missing remote uninstall result")
        }
        XCTAssertEqual(localCommands, 0, "Legacy remote views must never invoke the Mac plugin installer.")
        let previous = mac.apiSocketPath
        mac.reconnect()
        for _ in 0..<300 where mac.snapshot == nil || mac.busy { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNil(mac.error)
        XCTAssertEqual(mac.snapshot?.bootID, boot)
        XCTAssertNotEqual(mac.apiSocketPath, previous)
        XCTAssertFalse(FileManager.default.fileExists(atPath: previous))
        host.handle(.init(identity: identity, sequence: 2, bootID: boot, operation: .resize(columns: 79, rows: 24)))
        for _ in 0..<100 where phoneState?.sequence != 2 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(phoneState?.sequence, 2)
        XCTAssertNil(phoneState?.error)
        XCTAssertEqual(phoneState?.snapshot?.bootID, boot)
        let paths = [mac.apiSocketPath, phone.apiSocketPath]
        mac.stop(); host.stop()
        XCTAssertTrue(paths.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
    }

    private func waitForMachines(_ directory: MachineDirectory) async throws {
        for _ in 0..<300 {
            let remote = directory.state.entries.filter { $0.endpoint.profileID != nil }
            if remote.count == 2, remote.allSatisfy({ $0.health == .online }) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Remote machines did not connect: \(directory.state.entries)")
        throw MachineCatalogError.invalid("The disposable SSH machines did not connect.")
    }
}
