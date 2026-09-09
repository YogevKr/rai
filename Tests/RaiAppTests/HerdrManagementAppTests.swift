import AppKit
import RaiCore
import XCTest
@testable import RaiApp

final class HerdrManagementAppTests: XCTestCase {
    func testManagementActionsRequireAnAuditRecord() throws {
        for action in HerdrManagementAction.allCases {
            let request = HerdrManagementRequest(action: action, connectionID: "confirmed-server")
            let event = try XCTUnwrap(BridgeAuditEvent(.manageHerdr(request)))
            XCTAssertEqual(event.action, action.rawValue)
            XCTAssertEqual(event.targetIDs, ["connection_id": request.connectionID, "request_id": request.id])
            XCTAssertNil(BridgeAuditEvent(.herdrManagementResult(.init(request: request, text: "Completed"))))
        }
    }

    @MainActor
    func testModelRejectsAnUnconfirmedServerBeforeRunningACommand() async throws {
        _ = NSApplication.shared
        let suite = "HerdrManagementAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "companionBridgeEnabled")
        let model = RaiModel(client: HerdrClient(socketPath: "/tmp/rai-management-\(UUID().uuidString).sock"),
                             userDefaults: defaults, resolveHerdrBinary: { nil })
        for action in HerdrManagementAction.allCases {
            let request = HerdrManagementRequest(action: action, connectionID: "unconfirmed-server")
            let result = await model.manageHerdr(request)
            XCTAssertEqual(result.request, request)
            XCTAssertTrue(result.text.contains("target changed"))
        }
        await model.shutdown()
    }
}
