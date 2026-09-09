import Foundation
import RaiCore
import XCTest
@testable import rai

final class AgentExplanationBridgeTests: XCTestCase {
    private func snapshot() throws -> SessionSnapshot {
        try JSONDecoder().decode(SessionSnapshot.self, from: Data(#"{"version":"0.9.0","protocol":22,"workspaces":[],"tabs":[],"panes":[],"layouts":[]}"#.utf8))
    }

    private func capabilities(_ connectionID: String) throws -> BridgeHostCapabilities {
        let server = try JSONDecoder().decode(HerdrServerInfo.self, from: Data(#"{"version":"0.9.0","protocol":22}"#.utf8))
        return BridgeHostCapabilities(operations: [BridgeCapability.agentExplanation], server: server, connectionID: connectionID)
    }

    @MainActor
    func testRequestAndReplyUseTheAdvertisedConnection() async throws {
        let sent = expectation(description: "explanation request sent")
        var sentRequestID: String?
        let connection = BridgeConnection(messageSender: { message in
            guard case let .explainAgent(paneID, requestID, connectionID) = message else { return }
            XCTAssertEqual(paneID, "w1:p1")
            XCTAssertEqual(connectionID, "original")
            sentRequestID = requestID
            sent.fulfill()
        })
        connection.finishAuthentication(protocolVersion: bridgeProtocolVersion, sessionName: "lab")
        connection.handle(.snapshot(try snapshot(), sessionName: "lab", capabilities: try capabilities("original")))
        connection.requestAgentExplanation(paneID: "w1:p1")
        await fulfillment(of: [sent], timeout: 1)
        let requestID = try XCTUnwrap(sentRequestID)
        connection.handle(.agentExplanation(AgentExplanation(paneID: "w1:p1", requestID: requestID, connectionID: "original", text: "Muse is idle.")))
        XCTAssertEqual(connection.agentExplanation?.text, "Muse is idle.")
        XCTAssertTrue(connection.status.isConnected)
    }

    @MainActor
    func testServerReplacementRejectsTheOldExplanation() throws {
        let connection = BridgeConnection(messageSender: { _ in })
        connection.finishAuthentication(protocolVersion: bridgeProtocolVersion, sessionName: "lab")
        connection.handle(.snapshot(try snapshot(), sessionName: "lab", capabilities: try capabilities("original")))
        connection.agentExplanation = AgentExplanation(paneID: "w1:p1", requestID: "request", connectionID: "original")
        connection.handle(.snapshot(try snapshot(), sessionName: "lab", capabilities: try capabilities("replacement")))
        connection.handle(.agentExplanation(AgentExplanation(paneID: "w1:p1", requestID: "request", connectionID: "original", text: "STALE CONTENT")))
        XCTAssertEqual(connection.agentExplanation?.text, "The server connection changed. Request the explanation again.")
    }

    @MainActor
    func testLegacyMacDoesNotReceiveUnsupportedRequest() {
        let connection = BridgeConnection(messageSender: { message in
            if case .explainAgent = message { XCTFail("Must not send an unsupported operation") }
        })
        connection.finishAuthentication(protocolVersion: bridgeProtocolVersion, sessionName: "legacy")
        connection.requestAgentExplanation(paneID: "w1:p1")
        XCTAssertNil(connection.agentExplanation)
    }
}
