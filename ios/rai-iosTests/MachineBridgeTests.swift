import Foundation
import RaiCore
import XCTest
@testable import rai

@MainActor
final class MachineBridgeTests: XCTestCase {
    private func host(_ id: String) throws -> BridgeMessage {
        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(
            #"{"version":"0.9.0","protocol":22,"workspaces":[],"tabs":[],"panes":[],"layouts":[]}"#.utf8))
        return .snapshot(snapshot, sessionName: "local", capabilities: .init(
            operations: [BridgeCapability.nativeEndpoint, BridgeCapability.machineDirectory, BridgeCapability.notificationActions], server: nil, connectionID: id))
    }

    func testMachineSelectionUsesItsOwnConnectionAndIgnoresLegacyHostSelectionChanges() async throws {
        var requests: [EndpointBridgeRequest] = []
        let connection = BridgeConnection(messageSender: { if case .endpointRequest(let request) = $0 { requests.append(request) } })
        defer { connection.disconnect() }
        connection.finishAuthentication(protocolVersion: bridgeProtocolVersion, sessionName: "local")
        connection.handle(try host("host-one"))
        let endpoint = MachineEndpoint(profileID: String(repeating: "a", count: 32), session: "review")
        let entry = MachineEntry(endpoint: endpoint, label: "Remote", connectionID: "remote-one", health: .online)
        connection.handle(.machineState(.init(entries: [entry])))
        connection.selectMachine(entry)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.identity.machineEndpoint, endpoint)
        XCTAssertEqual(requests.first?.identity.connectionID, "remote-one")
        let identity = connection.endpointView.identity
        connection.handle(try host("host-two"))
        XCTAssertEqual(connection.endpointView.identity, identity)
    }

    func testReconnectRefreshesDirectoryBeforeOpeningTheSelectedMachineWithoutReplayingWrites() async throws {
        var requests: [EndpointBridgeRequest] = []
        var operations: [MachineOperation] = []
        let connection = BridgeConnection(messageSender: { message in
            if case .endpointRequest(let request) = message { requests.append(request) }
            if case .machineRequest(let request) = message { operations.append(request.operation) }
        })
        defer { connection.disconnect() }
        connection.finishAuthentication(protocolVersion: bridgeProtocolVersion, sessionName: "local")
        connection.handle(try host("host-one"))
        let endpoint = MachineEndpoint(profileID: String(repeating: "a", count: 32), session: "review")
        let first = MachineEntry(endpoint: endpoint, label: "Remote", connectionID: "remote-one", health: .online)
        connection.handle(.machineState(.init(entries: [first])))
        connection.selectMachine(first)
        for _ in 0..<20 { await Task.yield() }
        let original = try XCTUnwrap(requests.first?.identity)
        connection.scheduleReconnect(after: URLError(.networkConnectionLost))
        connection.finishAuthentication(protocolVersion: bridgeProtocolVersion, sessionName: "local")
        connection.handle(try host("host-two"))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(operations, [.refresh, .refresh])
        connection.handle(.machineState(.init(entries: [.init(endpoint: endpoint, label: "Remote", connectionID: "remote-two", health: .online)])))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(requests.count, 2)
        XCTAssertNotEqual(requests.last?.identity.viewID, original.viewID)
        XCTAssertEqual(requests.last?.identity.connectionID, "remote-two")
        XCTAssertEqual(requests.last?.sequence, 1)
        XCTAssertNil(requests.last?.bootID)
        XCTAssertTrue(requests.allSatisfy { if case .open = $0.operation { return true }; return false })
    }

    func testDisconnectedMachineCannotReplaceTheSelectedView() async throws {
        let connection = BridgeConnection(messageSender: { _ in })
        defer { connection.disconnect() }
        connection.finishAuthentication(protocolVersion: bridgeProtocolVersion, sessionName: "local")
        connection.handle(try host("local"))
        connection.openEndpointView()
        let identity = connection.endpointView.identity
        let entry = MachineEntry(endpoint: .init(profileID: String(repeating: "a", count: 32), session: "default"), label: "Offline")
        connection.handle(.machineState(.init(entries: [entry])))
        connection.selectMachine(entry)
        XCTAssertEqual(connection.endpointView.identity, identity)
    }
    func testNotificationWaitsForFreshDirectoryAndNeverOpensPreviousMachine() async throws {
        var requests: [EndpointBridgeRequest] = []
        let connection = BridgeConnection(messageSender: { if case .endpointRequest(let request) = $0 { requests.append(request) } })
        defer { connection.disconnect() }
        connection.finishAuthentication(protocolVersion: bridgeProtocolVersion, sessionName: "local")
        connection.handle(try host("host-one"))
        let endpoint = MachineEndpoint(profileID: String(repeating: "a", count: 32), session: "review")
        let old = MachineResource(endpoint: endpoint, connectionID: "old", bootID: "boot", paneID: "w1:p1")
        connection.openMachineNotification(old)
        connection.openEndpointView()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(requests.isEmpty)
        let fresh = MachineResource(endpoint: endpoint, connectionID: "fresh", bootID: "boot", paneID: "w1:p1")
        let agent = MachineAgent(resource: fresh, name: "Build", agent: "codex", status: "blocked")
        connection.handle(.machineState(.init(entries: [.init(endpoint: endpoint, label: "Remote", connectionID: "fresh", health: .online, agents: [agent])])))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.identity.machineEndpoint, endpoint)
        XCTAssertEqual(requests.first?.identity.connectionID, "fresh")
        XCTAssertTrue(requests.allSatisfy { if case .open = $0.operation { return true }; return false })
    }

    func testStaleNotificationBootCannotOpenAnyPaneUntilExplicitSelection() async throws {
        var requests: [EndpointBridgeRequest] = []
        let connection = BridgeConnection(messageSender: { if case .endpointRequest(let request) = $0 { requests.append(request) } })
        defer { connection.disconnect() }
        connection.finishAuthentication(protocolVersion: bridgeProtocolVersion, sessionName: "local")
        connection.handle(try host("host"))
        let endpoint = MachineEndpoint(profileID: String(repeating: "a", count: 32), session: "review")
        let old = MachineResource(endpoint: endpoint, connectionID: "old", bootID: "old-boot", paneID: "w1:p1")
        let fresh = MachineResource(endpoint: endpoint, connectionID: "fresh", bootID: "new-boot", paneID: "w1:p1")
        let entry = MachineEntry(endpoint: endpoint, label: "Remote", connectionID: "fresh", health: .online,
                                 agents: [.init(resource: fresh, name: "Build", agent: "codex", status: "blocked")])
        connection.openMachineNotification(old)
        connection.handle(.machineState(.init(entries: [entry])))
        connection.openEndpointView()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(connection.actionError?.contains("server changed") == true)
        connection.selectMachine(entry)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(requests.count, 1)
    }

    func testNotificationAfterDismissalDoesNotCloseTheOldViewAgain() async throws {
        var requests: [EndpointBridgeRequest] = []
        let connection = BridgeConnection(messageSender: {
            if case .endpointRequest(let request) = $0 { requests.append(request) }
        })
        defer { connection.disconnect() }
        connection.finishAuthentication(protocolVersion: bridgeProtocolVersion, sessionName: "local")
        connection.handle(try host("host"))
        connection.openEndpointView()
        for _ in 0..<20 { await Task.yield() }
        connection.closeEndpointView()
        for _ in 0..<20 { await Task.yield() }
        let endpoint = MachineEndpoint(profileID: String(repeating: "a", count: 32), session: "default")
        let resource = MachineResource(endpoint: endpoint, connectionID: "remote", bootID: "boot", paneID: "w1:p1")
        connection.openMachineNotification(resource)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(requests.filter { $0.operation == .close }.count, 1)
        let agent = MachineAgent(resource: resource, name: "Build", agent: "codex", status: "working")
        connection.handle(.machineState(.init(entries: [
            .init(endpoint: endpoint, label: "Remote", connectionID: "remote", health: .online, agents: [agent])
        ])))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(requests.filter { $0.operation == .close }.count, 1)
        XCTAssertEqual(requests.last?.identity.machineEndpoint, endpoint)
        XCTAssertEqual(requests.last?.operation, .open(columns: 80, rows: 32))
    }

    func testRetainedRemoteViewSurvivesMainSessionChangeAndEndsOnTransportDisconnect() async throws {
        var requests: [EndpointBridgeRequest] = []
        let connection = BridgeConnection(messageSender: { if case .endpointRequest(let request) = $0 { requests.append(request) } })
        defer { connection.disconnect() }
        connection.finishAuthentication(protocolVersion: bridgeProtocolVersion, sessionName: "remote")
        connection.handle(try host("remote-main"))
        connection.openEndpointView()
        for _ in 0..<30 { await Task.yield() }
        let identity = try XCTUnwrap(connection.endpointView.identity)
        let snapshot = try JSONDecoder().decode(HerdrEndpointSnapshot.self,
            from: Data(#"{"boot_id":"remote-boot","revision":1,"focused_pane_id":"w1:p1","panes":[{"pane_id":"w1:p1"}]}"#.utf8))
        var state = EndpointBridgeState(identity: identity, sequence: 1, snapshot: snapshot, surface: nil,
            methods: ["pane.focus"], busy: false, error: nil)
        state.retainsHostConnection = true
        connection.handle(.endpointState(state))
        connection.handle(try host("new-local-main"))
        XCTAssertEqual(connection.endpointView.identity, identity)
        XCTAssertTrue(connection.endpointView.retainsHostConnection)
        connection.endpointView.command(.focusPane("w1:p1"))
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(requests.last?.identity, identity)
        XCTAssertEqual(requests.last?.bootID, "remote-boot")
        XCTAssertEqual(requests.last?.operation, .command(.focusPane("w1:p1")))
        let count = requests.count
        connection.disconnect()
        XCTAssertNil(connection.endpointView.identity)
        XCTAssertFalse(connection.endpointView.retainsHostConnection)
        connection.endpointView.command(.focusPane("w1:p1"))
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(requests.count, count)
    }

    func testForeignOrMissingRetentionStateCannotKeepAnOldHostIdentity() async throws {
        for foreign in [false, true] {
            let connection = BridgeConnection(messageSender: { _ in })
            defer { connection.disconnect() }
            connection.finishAuthentication(protocolVersion: bridgeProtocolVersion, sessionName: "remote")
            connection.handle(try host("old-host"))
            connection.openEndpointView()
            for _ in 0..<30 { await Task.yield() }
            let identity = try XCTUnwrap(connection.endpointView.identity)
            var state = EndpointBridgeState(identity: foreign ? .init(connectionID: identity.connectionID) : identity,
                sequence: 1, snapshot: nil, surface: nil, methods: [], busy: false, error: nil)
            if foreign { state.retainsHostConnection = true }
            let decoded = try JSONDecoder().decode(EndpointBridgeState.self, from: JSONEncoder().encode(state))
            connection.handle(.endpointState(decoded))
            XCTAssertFalse(connection.endpointView.retainsHostConnection)
            connection.handle(try host("replacement-host"))
            XCTAssertNotEqual(connection.endpointView.identity, identity)
        }
    }

    func testWorkspaceCloseRejectsConfirmationFromAPreviousConnection() async throws {
        var closes: [BridgeMessage] = []
        let connection = BridgeConnection(messageSender: { message in
            if case .closeWorkspace = message { closes.append(message) }
        })
        defer { connection.disconnect() }
        connection.finishAuthentication(protocolVersion: bridgeProtocolVersion, sessionName: "local")
        connection.handle(try host("new-host"))
        connection.closeWorkspace(workspaceID: "w1", expectedConnectionID: "old-host")
        connection.closeWorkspace(workspaceID: "w1", expectedConnectionID: nil)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(closes.isEmpty)
        connection.closeWorkspace(workspaceID: "w1", expectedConnectionID: "new-host")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(closes, [.closeWorkspace(workspaceID: "w1", connectionID: "new-host")])
        connection.disconnect()
        connection.closeWorkspace(workspaceID: "w1", expectedConnectionID: "new-host")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(closes.count, 1)
    }

    func testRejectedNotificationReplyDetachesOnlyItsUnownedCurrentGenerationStream() async throws {
        let scenarios = [
            (name: "temporary", ownedBefore: false, ownedDuring: false, reconnect: false, detaches: 1),
            (name: "existing owner", ownedBefore: true, ownedDuring: false, reconnect: false, detaches: 0),
            (name: "new owner", ownedBefore: false, ownedDuring: true, reconnect: false, detaches: 0),
            (name: "new generation", ownedBefore: false, ownedDuring: false, reconnect: true, detaches: 0)
        ]
        for scenario in scenarios {
            let attached = expectation(description: "attached: \(scenario.name)")
            let flushed = expectation(description: "first line sent: \(scenario.name)")
            var attachments = 0
            var detaches: [String] = []
            var inputs: [String] = []
            var actions: [HostNotificationAction] = []
            let connection = BridgeConnection(messageSender: { message in
                switch message {
                case .attachStream:
                    attachments += 1
                    if attachments == 1 { attached.fulfill() }
                case .detachStream(let paneID):
                    detaches.append(paneID)
                case .input(_, let bytes):
                    inputs.append(String(decoding: Data(base64Encoded: bytes)!, as: UTF8.self))
                    flushed.fulfill()
                case .notificationAction(let action):
                    actions.append(action)
                default:
                    break
                }
            })
            defer { connection.disconnect() }
            connection.finishAuthentication(protocolVersion: bridgeProtocolVersion, sessionName: "local")
            connection.handle(try host("current-host"))
            if scenario.ownedBefore { connection.openPane(paneID: "w1:p1") }
            let pairing = try Pairing(host: "fixture.invalid", port: 9876, token: "fixture")
            let reply = Task {
                await connection.connectAndSendComposedLine(
                    Array("notification reply\r".utf8), to: "w1:p1", pairing: pairing,
                    expectedConnectionID: "current-host")
            }
            await fulfillment(of: [attached], timeout: 2)
            for _ in 0..<100 where connection.actionError != PasswordPromptGuard.waiting {
                await Task.yield()
            }
            XCTAssertEqual(connection.actionError, PasswordPromptGuard.waiting, scenario.name)
            let first = await connection.sendComposedLine(Array("first\r".utf8), to: "w1:p1")
            let second = await connection.sendComposedLine(Array("second\r".utf8), to: "w1:p1")
            XCTAssertEqual(first, .queued, scenario.name)
            XCTAssertEqual(second, .queued, scenario.name)
            if scenario.ownedDuring { connection.openPane(paneID: "w1:p1") }
            if scenario.reconnect {
                connection.finishAuthentication(protocolVersion: bridgeProtocolVersion, sessionName: "local")
                connection.handle(try host("replacement-host"))
            }
            connection.handle(.paneFrame(
                paneID: "w1:p1", bytesBase64: Data("\u{1B}[H$ ".utf8).base64EncodedString(),
                full: true, seq: 0, cols: 80, rows: 24))
            await fulfillment(of: [flushed], timeout: 2)
            let delivered = await reply.value

            XCTAssertFalse(delivered, scenario.name)
            XCTAssertEqual(connection.actionError, "Review the queued input before replying to this notification.", scenario.name)
            XCTAssertEqual(inputs, ["first\r"], scenario.name)
            XCTAssertEqual(connection.outbox.map(\.text), ["second\r"], scenario.name)
            XCTAssertTrue(actions.isEmpty, scenario.name)
            XCTAssertEqual(detaches, Array(repeating: "w1:p1", count: scenario.detaches), scenario.name)
        }
    }

    func testNotificationInputRejectsChangedHostAndCarriesMatchingIdentity() async throws {
        var actions: [HostNotificationAction] = []
        var rawInputs = 0
        let connection = BridgeConnection(messageSender: { message in
            if case .notificationAction(let action) = message { actions.append(action) }
            if case .input = message { rawInputs += 1 }
        })
        defer { connection.disconnect() }
        connection.finishAuthentication(protocolVersion: bridgeProtocolVersion, sessionName: "local")
        connection.handle(try host("current-host"))
        let pairing = try Pairing(host: "fixture.invalid", port: 9876, token: "fixture")
        let stale = await connection.connectAndSendInput([121], to: "w1:p1", pairing: pairing, expectedConnectionID: "old-host")
        XCTAssertFalse(stale)
        XCTAssertTrue(actions.isEmpty)
        let sent = await connection.connectAndSendInput([121], to: "w1:p1", pairing: pairing, expectedConnectionID: "current-host")
        XCTAssertTrue(sent)
        XCTAssertEqual(actions.first?.connectionID, "current-host")
        XCTAssertEqual(rawInputs, 0)
        let reply = await connection.sendComposedLine([121, 13], to: "w1:p1", expectedConnectionID: "old-host")
        XCTAssertEqual(reply, .refused)
        XCTAssertTrue(connection.outbox.isEmpty)
    }

}
