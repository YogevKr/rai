import Foundation
import RaiCore
import XCTest
@testable import rai

final class HerdrManagementBridgeTests: XCTestCase {
    @MainActor
    private func connect(_ connection: BridgeConnection, identity: String) throws {
        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(#"{"version":"0.9.0","protocol":22,"workspaces":[],"tabs":[],"panes":[],"layouts":[]}"#.utf8))
        let server = try JSONDecoder().decode(HerdrServerInfo.self, from: Data(#"{"version":"0.9.0","protocol":22,"capabilities":{"live_handoff":true}}"#.utf8))
        connection.finishAuthentication(protocolVersion: bridgeProtocolVersion, sessionName: "lab")
        connection.handle(.snapshot(snapshot, sessionName: "lab", capabilities: BridgeHostCapabilities(
            operations: [BridgeCapability.herdrManagement], server: server, connectionID: identity
        )))
    }

    @MainActor
    func testStaleConfirmationDoesNotSendAManagementAction() throws {
        let connection = BridgeConnection(messageSender: { message in
            if case .manageHerdr = message { XCTFail("Must reject the stale confirmation") }
        })
        try connect(connection, identity: "replacement")
        connection.manageHerdr(.init(action: .liveHandoff, connectionID: "original"))
        XCTAssertNil(connection.herdrManagementRequest)
        XCTAssertTrue(connection.herdrManagementText?.contains("target changed") == true)
    }

    @MainActor
    func testHandoffResultCanArriveAfterTheServerIdentityChanges() async throws {
        let sent = expectation(description: "one handoff request")
        sent.assertForOverFulfill = true
        let request = HerdrManagementRequest(action: .liveHandoff, connectionID: "original")
        let connection = BridgeConnection(messageSender: { message in
            if case let .manageHerdr(actual) = message {
                XCTAssertEqual(actual, request)
                sent.fulfill()
            }
        })
        try connect(connection, identity: "original")
        connection.manageHerdr(request)
        connection.manageHerdr(request)
        await fulfillment(of: [sent], timeout: 1)
        try connect(connection, identity: "replacement")
        connection.handle(.herdrManagementResult(.init(request: .init(action: .updateClient, connectionID: "original"), text: "Wrong request")))
        XCTAssertEqual(connection.herdrManagementRequest, request)
        connection.handle(.herdrManagementResult(.init(request: request, text: "Handoff completed")))
        XCTAssertNil(connection.herdrManagementRequest)
        XCTAssertEqual(connection.herdrManagementText, "Handoff completed")
    }

    @MainActor
    func testLegacyMacDoesNotReceiveManagementActions() {
        let connection = BridgeConnection(messageSender: { message in
            if case .manageHerdr = message { XCTFail("Must not send an unsupported operation") }
        })
        connection.finishAuthentication(protocolVersion: bridgeProtocolVersion, sessionName: "legacy")
        connection.manageHerdr(.init(action: .updateClient, connectionID: "legacy"))
        XCTAssertNil(connection.herdrManagementRequest)
    }

    @MainActor
    func testSocketRecoveryClearsPendingActionWithoutReplay() async throws {
        let sent = expectation(description: "one update request")
        sent.assertForOverFulfill = true
        let connection = BridgeConnection(messageSender: { message in
            if case .manageHerdr = message { sent.fulfill() }
        })
        defer { connection.disconnect() }
        try connect(connection, identity: "original")
        let request = HerdrManagementRequest(action: .updateClient, connectionID: "original")
        connection.manageHerdr(request)
        await fulfillment(of: [sent], timeout: 1)
        connection.scheduleReconnect(after: URLError(.networkConnectionLost))
        XCTAssertNil(connection.herdrManagementRequest)
        XCTAssertTrue(connection.herdrManagementText?.contains("may still complete") == true)
        try connect(connection, identity: "replacement")
        connection.handle(.herdrManagementResult(.init(request: request, text: "Late result")))
        XCTAssertTrue(connection.herdrManagementText?.contains("may still complete") == true)
    }

    @MainActor
    func testAuditRejectionCompletesOnlyTheMatchingRequest() throws {
        let connection = BridgeConnection(messageSender: { _ in })
        try connect(connection, identity: "original")
        let request = HerdrManagementRequest(action: .updateClient, connectionID: "original")
        connection.manageHerdr(request)
        connection.handle(.error(message: "Unrelated rejection", code: .auditUnavailable, requestID: "other"))
        XCTAssertEqual(connection.herdrManagementRequest, request)
        connection.handle(.error(message: "Audit unavailable", code: .auditUnavailable, requestID: request.id))
        XCTAssertNil(connection.herdrManagementRequest)
        XCTAssertEqual(connection.herdrManagementText, "Audit unavailable")
        XCTAssertTrue(connection.status.isConnected)
    }
    @MainActor
    func testServerStopRequiresSeparateCapability() throws {
        var sent: [HerdrManagementRequest] = []
        let connection = BridgeConnection(messageSender: { message in
            if case .manageHerdr(let request) = message { sent.append(request) }
        })
        defer { connection.disconnect() }
        try connect(connection, identity: "confirmed")
        connection.manageHerdr(.init(action: .stopServer, connectionID: "confirmed"))
        XCTAssertTrue(sent.isEmpty)
        XCTAssertNil(connection.herdrManagementRequest)
    }

}
