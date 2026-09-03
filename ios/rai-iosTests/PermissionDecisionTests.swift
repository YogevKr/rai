import Foundation
import RaiCore
import UserNotifications
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
            requestID: "request-a",
            timestamp: 1,
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

    func testFallbackDecisionBarRequiresCurrentClaudeRequest() {
        let request = AgentBeacon(
            event: "PermissionRequest",
            paneID: "pane-1",
            sessionID: "session",
            cwd: "/repo",
            transcriptPath: "/tmp/a",
            requestID: "request-a",
            timestamp: 1,
            awaitsDecision: true
        )

        XCTAssertFalse(FallbackDecisionBarGate.allows(
            renderedPaneID: "pane-1",
            renderedAgent: "codex",
            renderedBeacon: request,
            currentPaneID: "pane-1",
            currentBeacon: request
        ))
        XCTAssertTrue(FallbackDecisionBarGate.allows(
            renderedPaneID: "pane-1",
            renderedAgent: "claude",
            renderedBeacon: request,
            currentPaneID: "pane-1",
            currentBeacon: request
        ))
        XCTAssertFalse(FallbackDecisionBarGate.allows(
            renderedPaneID: "pane-1",
            renderedAgent: "claude",
            renderedBeacon: request,
            currentPaneID: "pane-1",
            currentBeacon: request.withDecisionRequestForTesting("request-b")
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

    @MainActor
    func testForegroundRefreshesNotificationAuthorizationEveryTime() async {
        let reader = NotificationAuthorizationReaderSpy([
            .authorized,
            .denied,
        ])
        let delegate = IOSAppDelegate(notificationAuthorizationReader: reader)

        delegate.updateScenePhase(.active)
        let first = expectation(description: "first authorization applied")
        DispatchQueue.main.async { first.fulfill() }
        await fulfillment(of: [first], timeout: 1)
        XCTAssertTrue(delegate.notificationAuthorizationGranted)

        delegate.updateScenePhase(.background)
        delegate.updateScenePhase(.active)
        let second = expectation(description: "revoked authorization applied")
        DispatchQueue.main.async { second.fulfill() }
        await fulfillment(of: [second], timeout: 1)
        XCTAssertFalse(delegate.notificationAuthorizationGranted)
        XCTAssertEqual(reader.readCount, 2)
    }

    @MainActor
    func testNewForegroundGrantStartsAPNsRegistrationOnce() async {
        let reader = NotificationAuthorizationReaderSpy([
            .denied,
            .authorized,
            .authorized,
        ])
        let registrations = LockedCounter()
        let delegate = IOSAppDelegate(
            notificationAuthorizationReader: reader,
            registerForRemoteNotifications: { registrations.increment() }
        )

        for expectedCount in [0, 1, 1] {
            delegate.updateScenePhase(.active)
            let applied = expectation(description: "authorization applied")
            DispatchQueue.main.async { applied.fulfill() }
            await fulfillment(of: [applied], timeout: 1)
            XCTAssertEqual(registrations.value, expectedCount)
            delegate.updateScenePhase(.background)
        }

        XCTAssertEqual(
            PushRegistrationPlan.messages(
                deviceToken: "token",
                environment: "sandbox",
                availability: PermissionDecisionAvailability(
                    notificationAuthorized: true,
                    appIsForeground: false
                )
            ),
            [
                .registerPush(deviceToken: "token", environment: "sandbox"),
                .decisionAvailability(available: true, pushAuthorized: true),
            ]
        )
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
            requestID: "request-a",
            timestamp: 10_000,
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
            requestID: "request-1",
            timestamp: 1
        )

        XCTAssertTrue(PermissionPromptTransport.usesLegacyKeys(beacon: oldBeacon))
        XCTAssertFalse(PermissionPromptTransport.usesLegacyKeys(beacon: closedDecision))
        XCTAssertTrue(
            PermissionPromptTransport.allowsEscape(
                promptKind: .askUserQuestion,
                beacon: closedDecision
            )
        )
        XCTAssertFalse(
            PermissionPromptTransport.allowsEscape(
                promptKind: .numberedPermission,
                beacon: closedDecision
            )
        )
    }
}

private final class NotificationAuthorizationReaderSpy:
    PhoneNotificationAuthorizationReading,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var statuses: [UNAuthorizationStatus]
    private(set) var readCount = 0

    init(_ statuses: [UNAuthorizationStatus]) {
        self.statuses = statuses
    }

    func readAuthorizationStatus(
        _ completion: @escaping @Sendable (UNAuthorizationStatus) -> Void
    ) {
        lock.lock()
        readCount += 1
        let status = statuses.removeFirst()
        lock.unlock()
        completion(status)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
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
            requestID: requestID,
            notificationType: notificationType,
            message: message,
            lastAssistantMessage: lastAssistantMessage,
            timestamp: timestamp,
            parentPID: parentPID,
            awaitsDecision: true,
            decisionHoldSeconds: decisionHoldSeconds,
            deadline: deadline
        )
    }
}
