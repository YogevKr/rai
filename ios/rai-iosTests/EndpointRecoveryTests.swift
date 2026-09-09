import Foundation
import RaiCore
import XCTest
@testable import rai

@MainActor
final class EndpointRecoveryTests: XCTestCase {
    private func snapshot(_ identity: String, supported: Bool = true) throws -> BridgeMessage {
        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(
            #"{"version":"0.9.0","protocol":22,"workspaces":[],"tabs":[],"panes":[],"layouts":[]}"#.utf8))
        return .snapshot(snapshot, sessionName: "lab", capabilities: BridgeHostCapabilities(
            operations: supported ? [BridgeCapability.nativeEndpoint] : [], server: nil, connectionID: identity))
    }

    func testVisibleWorkspaceReopensAfterRecoveryWithoutReplayingCommands() async throws {
        var requests: [EndpointBridgeRequest] = []
        let connection = BridgeConnection(messageSender: { message in
            if case let .endpointRequest(request) = message { requests.append(request) }
        })
        defer { connection.disconnect() }
        connection.openEndpointView()
        connection.finishAuthentication(protocolVersion: bridgeProtocolVersion, sessionName: "lab")
        connection.handle(try snapshot("original"))
        for _ in 0..<20 { await Task.yield() }
        let first = try XCTUnwrap(requests.first)
        let state = try JSONDecoder().decode(HerdrEndpointSnapshot.self, from: Data(
            #"{"boot_id":"boot","revision":1,"focused_pane_id":"w1:p1"}"#.utf8))
        connection.endpointView.receive(.init(identity: first.identity, sequence: 1,
            snapshot: state, surface: nil, methods: ["pane.focus"], busy: false, error: nil))
        connection.endpointView.command(.focusPane("w1:p2"))
        connection.scheduleReconnect(after: URLError(.networkConnectionLost))
        connection.finishAuthentication(protocolVersion: bridgeProtocolVersion, sessionName: "lab")
        connection.handle(try snapshot("replacement"))
        connection.handle(try snapshot("replacement"))
        connection.openEndpointView()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map(\.operation), [.open(columns: 80, rows: 32), .open(columns: 80, rows: 32)])
        XCTAssertEqual(requests.last?.identity.connectionID, "replacement")
        XCTAssertNotEqual(requests.last?.identity.viewID, first.identity.viewID)
        XCTAssertEqual(requests.last?.sequence, 1)
        XCTAssertNil(requests.last?.bootID)
    }

    func testClosedWorkspaceStaysClosedUntilRequestedAgain() async throws {
        var requests: [EndpointBridgeRequest] = []
        let connection = BridgeConnection(messageSender: { message in
            if case let .endpointRequest(request) = message { requests.append(request) }
        })
        defer { connection.disconnect() }
        connection.finishAuthentication(protocolVersion: bridgeProtocolVersion, sessionName: "lab")
        connection.handle(try snapshot("original"))
        connection.openEndpointView()
        for _ in 0..<20 { await Task.yield() }
        connection.closeEndpointView()
        for _ in 0..<20 { await Task.yield() }
        connection.scheduleReconnect(after: URLError(.networkConnectionLost))
        connection.finishAuthentication(protocolVersion: bridgeProtocolVersion, sessionName: "lab")
        connection.handle(try snapshot("replacement"))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(requests.map(\.operation), [.open(columns: 80, rows: 32), .close])
        XCTAssertNil(connection.endpointView.identity)
        connection.openEndpointView()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(requests.last?.identity.connectionID, "replacement")
        XCTAssertEqual(requests.count, 3)
    }

    func testPluginAuditRejectionClearsProgressAndReopenStartsANewSequence() async throws {
        var requests: [EndpointBridgeRequest] = []
        let connection = BridgeConnection(messageSender: { message in
            if case let .endpointRequest(request) = message { requests.append(request) }
        })
        defer { connection.disconnect() }
        connection.finishAuthentication(protocolVersion: bridgeProtocolVersion, sessionName: "lab")
        connection.handle(try snapshot("original"))
        connection.openEndpointView()
        for _ in 0..<20 { await Task.yield() }
        let first = try XCTUnwrap(requests.first)
        let endpointSnapshot = try JSONDecoder().decode(HerdrEndpointSnapshot.self, from: Data(
            #"{"boot_id":"boot","revision":1,"focused_pane_id":"w1:p1"}"#.utf8))
        let ready = EndpointBridgeState(identity: first.identity, sequence: 1,
            snapshot: endpointSnapshot, surface: nil, methods: ["plugin.list"], busy: false, error: nil)
        connection.handle(.endpointState(ready))
        let plugin = EndpointPluginRequest(bootID: "boot", operation: .list)
        XCTAssertTrue(connection.endpointView.performPlugin(plugin))
        for _ in 0..<20 { await Task.yield() }
        let rejected = try XCTUnwrap(requests.last)
        XCTAssertEqual(rejected.operation, .plugin(plugin))
        XCTAssertEqual(rejected.sequence, 2)
        XCTAssertTrue(connection.endpointView.busy)

        let message = "Bridge audit write failed."
        connection.handle(.error(message: message, code: .auditUnavailable, detail: nil,
            requestID: rejected.requestID))
        XCTAssertEqual(connection.actionError, message)
        XCTAssertEqual(connection.endpointView.error, message)
        XCTAssertEqual(connection.endpointView.state?.pluginResult, .init(requestID: plugin.id, error: message))
        XCTAssertFalse(connection.endpointView.busy, "Audit rejection must stop the progress indicator.")
        XCTAssertFalse(connection.endpointView.performPlugin(plugin), "A rejected sequence requires a new view.")
        connection.handle(.endpointState(ready))
        XCTAssertEqual(connection.endpointView.error, message, "Late state must not clear the rejection.")
        XCTAssertEqual(connection.endpointView.state?.pluginResult?.error, message)
        XCTAssertEqual(requests.count, 2, "Audit rejection must not replay the request.")

        connection.openEndpointView()
        for _ in 0..<20 { await Task.yield() }
        let reopened = try XCTUnwrap(requests.last)
        XCTAssertEqual(reopened.operation, .open(columns: 80, rows: 32))
        XCTAssertEqual(reopened.sequence, 1)
        XCTAssertNotEqual(reopened.identity.viewID, first.identity.viewID)
        XCTAssertNil(connection.endpointView.state?.pluginResult)
        let reopenedState = EndpointBridgeState(identity: reopened.identity, sequence: 1,
            snapshot: endpointSnapshot, surface: nil, methods: ["plugin.list"], busy: false, error: nil)
        connection.handle(.endpointState(reopenedState))
        let retry = EndpointPluginRequest(bootID: "boot", operation: .list)
        XCTAssertTrue(connection.endpointView.performPlugin(retry))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(requests.map(\.sequence), [1, 2, 1, 2])
        XCTAssertEqual(requests.last?.identity, reopened.identity)
        XCTAssertEqual(requests.last?.operation, .plugin(retry))
        connection.handle(.error(message: message, code: .auditUnavailable, detail: nil,
            requestID: rejected.requestID))
        XCTAssertNil(connection.endpointView.error, "An old view error must not reject the retry.")
        XCTAssertTrue(connection.endpointView.busy)
        var completed = EndpointBridgeState(identity: reopened.identity, sequence: 2,
            snapshot: endpointSnapshot, surface: nil, methods: ["plugin.list"], busy: false, error: nil)
        completed.pluginResult = .init(requestID: retry.id, value: .object(["plugins": .array([])]))
        connection.handle(.endpointState(completed))
        XCTAssertFalse(connection.endpointView.busy)
        XCTAssertNil(connection.endpointView.error)
        XCTAssertEqual(connection.endpointView.state?.pluginResult, completed.pluginResult)
    }

    func testUnsupportedHostNeverReceivesAnOpenRequest() async throws {
        let connection = BridgeConnection(messageSender: { message in
            if case .endpointRequest = message { XCTFail("Unsupported host received endpoint input") }
        })
        defer { connection.disconnect() }
        connection.openEndpointView()
        connection.finishAuthentication(protocolVersion: bridgeProtocolVersion, sessionName: "lab")
        connection.handle(try snapshot("legacy", supported: false))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(connection.endpointView.identity)
    }
}
