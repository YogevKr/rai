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
                for: PromptOption(digit: 1, label: " Yes\n")
            ),
            .allow
        )
        XCTAssertEqual(
            PermissionPromptDecisionMap.decision(
                for: PromptOption(digit: 2, label: "No")
            ),
            .deny
        )
        XCTAssertNil(
            PermissionPromptDecisionMap.decision(
                for: PromptOption(digit: 2, label: "yes")
            )
        )
        XCTAssertNil(
            PermissionPromptDecisionMap.decision(
                for: PromptOption(digit: 2, label: "Yes, and don't ask again")
            )
        )
        XCTAssertNil(
            PermissionPromptDecisionMap.decision(
                for: PromptOption(
                    digit: 3,
                    label: "No, and tell Claude what to do differently"
                )
            )
        )
        XCTAssertNil(
            PermissionPromptDecisionMap.decision(
                for: PromptOption(digit: 4, label: "Switch to auto mode")
            )
        )
    }

    func testRenderedDecisionRefusesAReplacementBeacon() {
        let requestA = AgentBeacon(
            event: "PermissionRequest",
            paneID: "pane-1",
            sessionID: "session",
            cwd: "/repo",
            transcriptPath: "/tmp/a",
            timestamp: 1,
            requestID: "request-a",
            awaitsDecision: true
        )
        let requestB = requestA.withDecisionRequestForTesting("request-b")

        XCTAssertFalse(PermissionDecisionTapGuard.isCurrent(
            capturedPaneID: "pane-1",
            capturedRequestID: "request-a",
            currentPaneID: "pane-1",
            currentBeacon: requestB
        ))
        XCTAssertTrue(PermissionDecisionTapGuard.isCurrent(
            capturedPaneID: "pane-1",
            capturedRequestID: "request-a",
            currentPaneID: "pane-1",
            currentBeacon: requestA
        ))
    }

    func testDeniedNotificationsAdvertiseOnlyWhileForeground() {
        let foreground = PermissionDecisionAvailability(
            notificationAuthorized: false,
            appIsForeground: true
        )
        let background = PermissionDecisionAvailability(
            notificationAuthorized: false,
            appIsForeground: false
        )
        let authorized = PermissionDecisionAvailability(
            notificationAuthorized: true,
            appIsForeground: false
        )

        XCTAssertTrue(foreground.available)
        XCTAssertFalse(foreground.capabilities.contains(BridgeCapability.permissionDecisionPush))
        XCTAssertFalse(background.available)
        XCTAssertTrue(authorized.available)
        XCTAssertTrue(authorized.capabilities.contains(BridgeCapability.permissionDecisionPush))
        XCTAssertFalse(PhoneNotificationRegistrationPolicy.shouldRegister(
            authorizationGranted: false
        ))
        XCTAssertTrue(PhoneNotificationRegistrationPolicy.shouldRegister(
            authorizationGranted: true
        ))
    }

    func testStaleSocketFailureKeepsNewSocketWaiter() {
        let oldSocket = NSObject()
        let newSocket = NSObject()
        let resolved = DecisionWaiterRouting.requestIDs(
            waiterSocketIDs: [
                "old-request": ObjectIdentifier(oldSocket),
                "new-request": ObjectIdentifier(newSocket),
            ],
            failingSocketID: ObjectIdentifier(oldSocket)
        )

        XCTAssertEqual(resolved, ["old-request"])
    }

    func testDecisionPresentationHidesMacOnlyChoices() {
        let options = [
            PromptOption(digit: 1, label: "Yes"),
            PromptOption(digit: 2, label: "Yes, and don't ask again"),
            PromptOption(digit: 3, label: "No"),
            PromptOption(digit: 4, label: "Switch to auto mode"),
        ]

        XCTAssertEqual(
            PermissionPromptPresentation.visibleOptions(options, awaitingDecision: true),
            [options[0], options[2]]
        )
        XCTAssertTrue(PermissionPromptPresentation.showsMacHint(
            options,
            awaitingDecision: true
        ))
    }

    func testCountdownIgnoresMacAndPhoneClockSkew() {
        let beacon = AgentBeacon(
            event: "PermissionRequest",
            sessionID: "session",
            cwd: "/repo",
            transcriptPath: "/tmp/a",
            timestamp: 10_000,
            requestID: "request-a",
            awaitsDecision: true,
            decisionHoldSeconds: 45,
            deadline: Date(timeIntervalSince1970: 10_080)
        )

        XCTAssertEqual(
            HeldDecisionCountdown.remainingSeconds(
                beacon: beacon,
                receivedAt: Date(timeIntervalSince1970: 500),
                now: Date(timeIntervalSince1970: 507)
            ),
            38
        )
        XCTAssertEqual(
            HeldDecisionCountdown.remainingSeconds(
                beacon: beacon,
                receivedAt: Date(timeIntervalSince1970: 500),
                now: Date(timeIntervalSince1970: 600)
            ),
            0
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

private extension AgentBeacon {
    func withDecisionRequestForTesting(_ requestID: String) -> AgentBeacon {
        AgentBeacon(
            event: event,
            paneID: paneID,
            herdrSocketPath: herdrSocketPath,
            sessionID: sessionID,
            cwd: cwd,
            transcriptPath: transcriptPath,
            toolName: toolName,
            toolInput: toolInput,
            notificationType: notificationType,
            message: message,
            lastAssistantMessage: lastAssistantMessage,
            timestamp: timestamp,
            parentPID: parentPID,
            requestID: requestID,
            awaitsDecision: true,
            decisionHoldSeconds: decisionHoldSeconds,
            deadline: deadline
        )
    }
}
