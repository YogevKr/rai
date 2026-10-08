import AppKit
import Combine
import RaiCore
import XCTest
@testable import RaiApp

@MainActor
final class MachineNavigationTransportTests: XCTestCase {
    func testEmptySSHMachineCreatesAndClosesThroughNativeSpaceModel() async throws {
        guard let target = ProcessInfo.processInfo.environment["RAI_NAVIGATION_E2E_TARGET"],
              let root = AppDataPaths.current.isolatedRoot,
              let fixture = try LabSSHConfiguration.load(root: root) else {
            throw XCTSkip("Requires an owned SSH lab and RAI_NAVIGATION_E2E_TARGET.")
        }
        try fixture.validate(target: target)
        _ = NSApplication.shared
        let defaultsName = "rai-native-machine-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { UserDefaults.standard.removePersistentDomain(forName: defaultsName) }
        let entry = MachineEntry(endpoint: .init(profileID: "native-test", session: "remote"),
                                 label: "Native SSH", target: target)
        let model = RaiModel(userDefaults: defaults, machineEntry: entry)
        defer { model.stopMachineConnection() }
        model.connectRemote(target: target, sessionName: entry.endpoint.session)
        try await wait("connect", model: model) { model.isConnected && model.snapshot != nil }
        XCTAssertEqual(model.snapshot?.workspaces.count, 0, "Connecting must not create a shell")
        guard model.snapshot?.workspaces.isEmpty == true else {
            XCTFail("The fixture must be empty. Existing spaces were left unchanged.")
            return
        }
        let primary = RaiModel(client: HerdrClient(socketPath: root.appendingPathComponent("unused.sock").path), userDefaults: defaults)
        let directory = MachineDirectory()
        let navigation = MachineNavigationController(primaryModel: primary, directory: directory,
                                                       connects: false, makeModel: { _ in model })
        navigation.reconcile([entry])
        navigation.selectMachine(entry.endpoint)
        navigation.newSpace()
        try await wait("first create", model: model) { !model.isCreatingWorkspace && model.snapshot?.workspaces.count == 1 && model.snapshot?.tabs.count == 1 }
        let workspace = try XCTUnwrap(model.snapshot?.workspaces.first)
        model.requestClose(workspace: workspace)
        model.confirmCloseWorkspace(try XCTUnwrap(model.workspacePendingClose))
        try await wait("reviewed close after empty startup", model: model) { model.snapshot?.workspaces.isEmpty == true }
        XCTAssertNil(model.sessionAlert)
        navigation.newSpace()
        try await wait("create after reviewed close", model: model) { !model.isCreatingWorkspace && model.snapshot?.workspaces.count == 1 && model.snapshot?.tabs.count == 1 }
        let first = try XCTUnwrap(model.snapshot?.panes.first?.terminalID)
        navigation.newSpace()
        try await wait("second create", model: model) { !model.isCreatingWorkspace && model.snapshot?.workspaces.count == 2 && model.snapshot?.tabs.count == 2 }
        XCTAssertTrue(model.snapshot?.panes.contains { $0.terminalID == first } == true)
        XCTAssertEqual(model.snapshot?.workspaces.map(\.tabCount), [1, 1])
        model.closeTab()
        try await wait("first close", model: model) { model.snapshot?.workspaces.count == 1 }
        model.closeTab()
        try await wait("final close", model: model) { model.snapshot?.workspaces.isEmpty == true }
        try await Task.sleep(for: .seconds(2))
        let empty = try await model.client.snapshot()
        XCTAssertTrue(empty.workspaces.isEmpty)
        XCTAssertTrue(empty.tabs.isEmpty)
        navigation.newSpace()
        try await wait("create again", model: model) { !model.isCreatingWorkspace && model.snapshot?.workspaces.count == 1 && model.snapshot?.tabs.count == 1 }
        model.closeTab()
        try await wait("close again", model: model) { model.snapshot?.workspaces.isEmpty == true }
        XCTAssertTrue(primary.snapshot == nil, "Remote controls must not connect the primary model")
    }

    func testSSHNavigationKeepsConnectionsAndDoesNotInjectInput() async throws {
        guard let target = ProcessInfo.processInfo.environment["RAI_NAVIGATION_E2E_TARGET"],
              let root = AppDataPaths.current.isolatedRoot,
              let fixture = try LabSSHConfiguration.load(root: root) else {
            throw XCTSkip("Requires an owned loopback SSH lab and RAI_NAVIGATION_E2E_TARGET.")
        }
        try fixture.validate(target: target)
        _ = NSApplication.shared
        let defaultsName = "rai-navigation-stream-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { UserDefaults.standard.removePersistentDomain(forName: defaultsName) }
        let entry = MachineEntry(endpoint: .init(profileID: "stream-test", session: "remote"),
                                 label: "Stream SSH", target: target)
        let model = RaiModel(userDefaults: defaults, machineEntry: entry)
        defer { model.stopMachineConnection() }
        model.connectRemote(target: target, sessionName: entry.endpoint.session)
        try await wait("connect", model: model) { model.isConnected && model.snapshot != nil }
        let client = model.client
        let before = try await client.snapshot()
        let firstID = try await client.createWorkspace()
        let secondID = try await client.createWorkspace()
        do {
            try await wait("fixture spaces", model: model) {
                model.snapshot?.workspaces.contains { $0.workspaceID == secondID } == true
            }
            let first = try XCTUnwrap(model.snapshot?.panes.first { $0.workspaceID == firstID })
            let second = try XCTUnwrap(model.snapshot?.panes.first { $0.workspaceID == secondID })
            let directory = root.appendingPathComponent("stream-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let received = directory.appendingPathComponent("input.bin")
            let ready = directory.appendingPathComponent("ready")
            let script = directory.appendingPathComponent("record.py")
            try """
            import os, sys, tty, threading, time
            tty.setraw(0)
            output = open(sys.argv[1], 'ab', buffering=0)
            open(sys.argv[2], 'w').write(str(os.getpid()))
            def emit():
                for index in range(60):
                    os.write(1, ('stream-%d\\r\\n' % index).encode())
                    time.sleep(0.1)
            threading.Thread(target=emit, daemon=True).start()
            while True:
                output.write(os.read(0, 1024))
            """.write(to: script, atomically: true, encoding: .utf8)
            let command = "/usr/bin/python3 \(script.path) \(received.path) \(ready.path)\n"
            try await client.sendInput(paneID: first.paneID, bytes: Array(command.utf8))
            try await wait("recorder", model: model) { FileManager.default.fileExists(atPath: ready.path) }
            let sourcePID = try String(contentsOf: ready)
            let path = model.activeSocketPath
            var states: [RaiModel.ConnectionState] = []
            let observation = model.$connectionState.sink { states.append($0) }
            defer { observation.cancel() }
            let frame = NSRect(x: 0, y: 0, width: 800, height: 480)
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            let host = NSView(frame: frame)
            window.contentView = host
            defer { window.contentView = nil }
            let firstView = try XCTUnwrap(model.terminalPool.view(for: first.terminalID))
            let secondView = try XCTUnwrap(model.terminalPool.view(for: second.terminalID))
            func show(_ view: FocusAwareTerminalView) {
                view.frame = frame
                host.addSubview(view)
                host.layoutSubtreeIfNeeded()
            }
            model.select(paneID: first.paneID, focusInHerdr: true)
            show(firstView)
            firstView.send(txt: "initial;")
            try await wait("first attach", model: model) { firstView.process?.running == true }
            let firstProcess = try XCTUnwrap(firstView.process)
            try await Task.sleep(for: .milliseconds(700))
            XCTAssertEqual(try Data(contentsOf: received), Data("initial;".utf8),
                           "Keep the first user input and do not add Ctrl-L")
            var secondProcessID: Int32?
            for index in 0..<3 {
                let earlierOutput = firstView.getTerminal().getBufferAsData()
                firstView.removeFromSuperview()
                model.select(paneID: second.paneID, focusInHerdr: true)
                show(secondView)
                try await Task.sleep(for: .milliseconds(1_200))
                XCTAssertTrue(firstView.process === firstProcess)
                XCTAssertNotEqual(firstView.getTerminal().getBufferAsData(), earlierOutput,
                                  "Hidden terminals must continue receiving output")
                let currentSecondProcessID = try XCTUnwrap(secondView.process?.shellPid)
                if let secondProcessID { XCTAssertEqual(currentSecondProcessID, secondProcessID) }
                secondProcessID = currentSecondProcessID
                secondView.removeFromSuperview()
                model.select(paneID: first.paneID, focusInHerdr: true)
                show(firstView)
                firstView.send(txt: "key-\(index);")
                try await Task.sleep(for: .milliseconds(300))
            }
            XCTAssertEqual(try Data(contentsOf: received), Data("initial;key-0;key-1;key-2;".utf8))
            XCTAssertEqual(try String(contentsOf: ready), sourcePID)
            XCTAssertTrue(String(decoding: firstView.getTerminal().getBufferAsData(), as: UTF8.self).contains("stream-"))
            XCTAssertTrue(states.allSatisfy { if case .connected = $0 { return true }; return false })
            XCTAssertEqual(model.activeSocketPath, path)
            model.select(paneID: "w999999:p999999", focusInHerdr: true)
            try await wait("rejected focus", model: model) { model.sessionAlert != nil }
            XCTAssertTrue(model.isConnected, "An action rejection is not an offline endpoint")
            XCTAssertEqual(model.selectedPaneID, first.paneID)
            XCTAssertTrue(firstView.process === firstProcess)
            let after = try await client.snapshot()
            XCTAssertEqual(after.panes.first { $0.paneID == first.paneID }?.terminalID, first.terminalID)
            XCTAssertEqual(after.panes.filter { ![firstID, secondID].contains($0.workspaceID) }.map(\.terminalID),
                           before.panes.map(\.terminalID))
            model.terminalPool.removeAll()
        } catch {
            model.terminalPool.removeAll()
            try? await client.closeWorkspace(firstID)
            try? await client.closeWorkspace(secondID)
            throw error
        }
        try await client.closeWorkspace(firstID)
        try await client.closeWorkspace(secondID)
    }

    private func wait(_ stage: String, model: RaiModel, _ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Stage: \(stage); connection: \(model.connectionState); spaces: \(model.snapshot?.workspaces.count ?? -1); selected: \(model.selectedPaneID ?? "none"); alert: \(String(describing: model.sessionAlert))")
        throw HerdrEndpointError.timedOut
    }
}
