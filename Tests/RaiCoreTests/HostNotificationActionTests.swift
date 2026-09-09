import Foundation
import XCTest
@testable import RaiCore

final class HostNotificationActionTests: XCTestCase {
    func testOldLocalActionCannotTargetANewLocalOrRemoteHost() throws {
        let action = HostNotificationAction(connectionID: "old-local", paneID: "w1:p1", operation: .input(bytesBase64: "eQ=="))
        XCTAssertTrue(action.isAllowed(currentConnectionID: "old-local", remote: false))
        XCTAssertFalse(action.isAllowed(currentConnectionID: "new-local", remote: false))
        XCTAssertFalse(action.isAllowed(currentConnectionID: "old-local", remote: true))
        XCTAssertFalse(action.isAllowed(currentConnectionID: nil, remote: false))
        let message = BridgeMessage.notificationAction(action)
        let data = try JSONEncoder().encode(message)
        guard case .notificationAction(let decoded) = try JSONDecoder().decode(BridgeMessage.self, from: data) else {
            return XCTFail("The notification action did not round trip.")
        }
        XCTAssertEqual(decoded, action)
    }
}
