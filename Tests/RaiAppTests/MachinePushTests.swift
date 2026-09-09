import Foundation
import RaiCore
import XCTest
@testable import RaiApp

final class MachinePushTests: XCTestCase {
    func testOlderRegistrationCannotReceiveScopedNotificationActions() throws {
        let legacy = try JSONDecoder().decode(PushRegistration.self, from: Data(
            #"{"deviceToken":"fixture","environment":"sandbox","decisionCapable":true}"#.utf8))
        XCTAssertFalse(legacy.supportsScopedNotifications)
        let current = PushRegistration(deviceToken: "fixture", environment: "sandbox", supportsScopedNotifications: true)
        XCTAssertTrue(try JSONDecoder().decode(PushRegistration.self,
            from: JSONEncoder().encode(current)).supportsScopedNotifications)
    }

    func testMachinePayloadPreservesIdentityAndRejectsLegacyApprovalFields() throws {
        let resource = MachineResource(endpoint: .init(profileID: String(repeating: "a", count: 32), session: "review"),
                                       connectionID: "one", bootID: "boot", paneID: "w1:p1")
        let event = PhonePushEvent(paneID: "w1:p1", paneName: "Build", workspaceID: "w1", workspaceName: "Remote",
                                  status: .blocked, allowsRemoteActions: true, requestID: "forged",
                                  occurredAt: Date(timeIntervalSince1970: 100), machineResource: resource)
        let burst = PhonePushBurst(events: [event])
        XCTAssertNil(burst.category)
        XCTAssertTrue(burst.canDeliver(remoteHost: true))
        XCTAssertEqual(burst.notificationIDs, [resource.notificationID])
        XCTAssertEqual(burst.threadID, resource.notificationID)
        let data = try APNsPayloadBuilder.alert(title: burst.title, subtitle: "Remote", body: burst.body,
            paneID: burst.paneID, requestID: burst.requestID, workspaceID: burst.workspaceID, workspace: burst.workspaceName,
            category: "permission-decision", notificationIDs: burst.notificationIDs, threadID: burst.threadID,
            summaryArgument: burst.summaryArgument, summaryArgumentCount: 1, occurredAt: burst.occurredAt,
            interruptionLevel: .timeSensitive, badge: 1, machineResource: resource)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let aps = try XCTUnwrap(payload["aps"] as? [String: Any])
        XCTAssertNil(aps["category"])
        XCTAssertNil(payload["paneID"])
        XCTAssertNil(payload["request_id"])
        XCTAssertEqual(MachineNotificationRoute.decode(payload), .machine(resource))
    }
    func testLocalPayloadCarriesCapturedHostConnection() throws {
        let local = PhonePushBurst(events: [.init(paneID: "w1:p1", paneName: "Build", workspaceID: "w1",
            workspaceName: "Local", status: .blocked, occurredAt: Date(), hostConnectionID: "captured-host")])
        XCTAssertFalse(local.canDeliver(remoteHost: true))
        XCTAssertTrue(local.canDeliver(remoteHost: false))
        let data = try APNsPayloadBuilder.alert(title: "Build", subtitle: "Local", body: "Needs review",
            paneID: "w1:p1", workspaceID: "w1", workspace: "Local", category: "agent-attention",
            notificationIDs: ["local"], threadID: "w1", summaryArgument: "Local", summaryArgumentCount: 1,
            occurredAt: Date(), interruptionLevel: .active, badge: nil, hostConnectionID: "captured-host")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(payload["hostConnectionID"] as? String, "captured-host")
    }

}
