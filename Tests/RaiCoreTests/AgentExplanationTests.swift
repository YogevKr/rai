import Foundation
import XCTest
@testable import RaiCore

final class AgentExplanationTests: XCTestCase {
    func testRepliesRequireMatchingRequestPaneAndConnection() {
        let pending = AgentExplanation(paneID: "w1:p1", requestID: "request", connectionID: "original")
        let reply = AgentExplanation(paneID: "w1:p1", requestID: "request", connectionID: "original", text: "Idle")
        XCTAssertTrue(pending.accepts(reply, connectionID: "original"))
        XCTAssertFalse(pending.accepts(reply, connectionID: "replacement"))
        XCTAssertFalse(pending.accepts(reply, connectionID: nil))
        XCTAssertFalse(pending.accepts(AgentExplanation(paneID: "w2:p1", requestID: "request", connectionID: "original"), connectionID: "original"))
        XCTAssertFalse(pending.accepts(AgentExplanation(paneID: "w1:p1", requestID: "older", connectionID: "original"), connectionID: "original"))
    }

    func testBridgeRequestAndResponseRoundTrip() throws {
        let messages: [BridgeMessage] = [
            .explainAgent(paneID: "w1:p1", requestID: "request", connectionID: "original"),
            .agentExplanation(AgentExplanation(paneID: "w1:p1", requestID: "request", connectionID: "original", text: "Muse is idle."))
        ]
        for message in messages {
            XCTAssertEqual(try JSONDecoder().decode(BridgeMessage.self, from: JSONEncoder().encode(message)), message)
        }
    }
}
