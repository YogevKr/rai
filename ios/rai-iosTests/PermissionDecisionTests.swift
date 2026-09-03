import RaiCore
import XCTest

@testable import rai

final class PermissionDecisionTests: XCTestCase {
    func testHeldPushUsesDecisionOnlyCategory() {
        XCTAssertEqual(PhoneNotificationAction.decisionCategory, "permission-decision")
    }

    func testNotificationActionsUseDecisionWhenRequestIDExists() {
        XCTAssertEqual(
            PhoneNotificationResponsePlan.make(
                actionIdentifier: PhoneNotificationAction.approve,
                requestID: "request-1"
            ),
            .decide(.allow, requestID: "request-1")
        )
        XCTAssertEqual(
            PhoneNotificationResponsePlan.make(
                actionIdentifier: PhoneNotificationAction.deny,
                requestID: "request-1"
            ),
            .decide(.deny, requestID: "request-1")
        )
    }

    func testNotificationActionsKeepLegacyKeystrokeFallback() {
        XCTAssertEqual(
            PhoneNotificationResponsePlan.make(
                actionIdentifier: PhoneNotificationAction.approve,
                requestID: nil
            ),
            .input([0x0D])
        )
        XCTAssertEqual(
            PhoneNotificationResponsePlan.make(
                actionIdentifier: PhoneNotificationAction.deny,
                requestID: nil
            ),
            .input([0x1B])
        )
    }

    func testPromptOptionsMapOnlyOneTimeYesAndNo() {
        XCTAssertEqual(
            PermissionPromptDecisionMap.decision(
                for: PromptOption(digit: 1, label: "Yes")
            ),
            .allow
        )
        XCTAssertNil(
            PermissionPromptDecisionMap.decision(
                for: PromptOption(digit: 2, label: "Yes, and don't ask again")
            )
        )
        XCTAssertEqual(
            PermissionPromptDecisionMap.decision(
                for: PromptOption(
                    digit: 3,
                    label: "No, and tell Claude what to do differently"
                )
            ),
            .deny
        )
        XCTAssertNil(
            PermissionPromptDecisionMap.decision(
                for: PromptOption(digit: 4, label: "Switch to auto mode")
            )
        )
    }

    func testLegacyKeysRequireABeaconWithoutARequestID() {
        let oldBeacon = AgentBeacon(
            event: "PermissionRequest",
            sessionID: "session-1",
            cwd: "/repo",
            transcriptPath: "/tmp/session.jsonl",
            timestamp: 1
        )
        let closedDecision = AgentBeacon(
            event: "PermissionRequest",
            sessionID: "session-1",
            cwd: "/repo",
            transcriptPath: "/tmp/session.jsonl",
            timestamp: 1,
            requestID: "request-1"
        )

        XCTAssertTrue(PermissionPromptTransport.usesLegacyKeys(beacon: oldBeacon))
        XCTAssertFalse(PermissionPromptTransport.usesLegacyKeys(beacon: closedDecision))
    }
}
