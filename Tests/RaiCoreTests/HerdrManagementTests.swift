import Foundation
import XCTest
@testable import RaiCore

final class HerdrManagementTests: XCTestCase {
    func testCapabilitiesRequireHostOperationIdentityAndServerSupport() throws {
        let server = try JSONDecoder().decode(HerdrServerInfo.self, from: Data(#"{"version":"0.9.0","protocol":22,"capabilities":{"live_handoff":true}}"#.utf8))
        let supported = BridgeHostCapabilities(operations: [BridgeCapability.herdrManagement, BridgeCapability.herdrServerStop], server: server, connectionID: "lab")
        for action in HerdrManagementAction.allCases {
            XCTAssertTrue(supported.supports(action))
            XCTAssertFalse(BridgeHostCapabilities(operations: [], server: server, connectionID: "lab").supports(action))
            XCTAssertFalse(BridgeHostCapabilities(operations: [BridgeCapability.herdrManagement], server: server).supports(action))
        }
        let older = try JSONDecoder().decode(HerdrServerInfo.self, from: Data(#"{"version":"0.8.2","protocol":20}"#.utf8))
        let capabilities = BridgeHostCapabilities(operations: [BridgeCapability.herdrManagement], server: older, connectionID: "lab")
        XCTAssertTrue(capabilities.supports(.updateClient))
        XCTAssertFalse(capabilities.supports(.liveHandoff))
        XCTAssertFalse(capabilities.supports(.stopServer), "Old hosts must not receive a new destructive action.")
    }

    func testManagementMessagesPreserveConfirmedTargetAndResult() throws {
        for action in HerdrManagementAction.allCases {
            let request = HerdrManagementRequest(action: action, connectionID: "confirmed-server")
            let messages: [BridgeMessage] = [.manageHerdr(request), .herdrManagementResult(.init(request: request, text: "Completed"))]
            for message in messages {
                XCTAssertEqual(try JSONDecoder().decode(BridgeMessage.self, from: JSONEncoder().encode(message)), message)
            }
        }
    }
}
