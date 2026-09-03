import AppKit
import Foundation
import RaiCore
import Security
import XCTest

@testable import RaiApp

final class PushPreferenceGateTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testKindTogglesApplyIndependently() {
        let now = date(hour: 12)
        let preferences = PushPreferences(kinds: .init(needsYou: false, finished: true))

        XCTAssertEqual(decision(.blocked, at: now, preferences: preferences), .kindDisabled)
        XCTAssertEqual(decision(.done, at: now, preferences: preferences), .allow)
    }

    func testDisabledKindIsDroppedWhenCaptured() {
        let now = date(hour: 12)
        let preferences = PushPreferences(kinds: .init(needsYou: false, finished: true))

        XCTAssertTrue(PushPreferenceGate.suppressesHeldEvent(
            status: .blocked,
            occurredAt: now,
            preferences: preferences,
            calendar: calendar
        ))
        XCTAssertFalse(PushPreferenceGate.suppressesHeldEvent(
            status: .done,
            occurredAt: now,
            preferences: preferences,
            calendar: calendar
        ))
    }

    func testDisablingKindMarksAlreadyHeldEventsAsDropped() throws {
        let event = PhonePushEvent(
            paneID: "pane-1",
            paneName: "Agent",
            workspaceID: "workspace-1",
            workspaceName: "Work",
            status: .blocked,
            occurredAt: date(hour: 12)
        )

        let updated = PushPreferenceGate.suppressDisabledKinds(
            in: [event.paneID: event],
            for: "phone-1",
            preferences: PushPreferences(kinds: .init(needsYou: false, finished: true))
        )
        let enabledAgain = PushPreferenceGate.suppressDisabledKinds(
            in: updated,
            for: "phone-1",
            preferences: .default
        )

        XCTAssertTrue(try XCTUnwrap(updated[event.paneID]).suppressedDeviceIDs.contains("phone-1"))
        XCTAssertTrue(
            try XCTUnwrap(enabledAgain[event.paneID]).suppressedDeviceIDs.contains("phone-1")
        )
        XCTAssertEqual(
            decision(.blocked, at: date(hour: 13), preferences: .default),
            .allow
        )
    }

    func testSnoozeDropsHeldEventsAfterSnoozeEnds() {
        let preferences = PushPreferences(snoozeUntil: date(hour: 13))

        XCTAssertEqual(
            decision(
                .blocked,
                at: date(hour: 14),
                occurredAt: date(hour: 12),
                preferences: preferences
            ),
            .snoozed
        )
        XCTAssertEqual(
            decision(
                .blocked,
                at: date(hour: 14),
                occurredAt: date(hour: 13, minute: 1),
                preferences: preferences
            ),
            .allow
        )
        XCTAssertTrue(PushPreferenceGate.suppressesHeldEvent(
            status: .blocked,
            occurredAt: date(hour: 12),
            preferences: preferences,
            calendar: calendar
        ))
    }

    func testDailyWindowHandlesSameDayAndMidnightRanges() {
        let daytime = PushPreferences(dnd: .init(start: 9 * 60, end: 17 * 60))
        XCTAssertEqual(decision(.done, at: date(hour: 9), preferences: daytime), .doNotDisturb)
        XCTAssertEqual(decision(.done, at: date(hour: 17), preferences: daytime), .allow)

        let overnight = PushPreferences(dnd: .init(start: 22 * 60, end: 8 * 60))
        XCTAssertEqual(decision(.blocked, at: date(hour: 23), preferences: overnight), .doNotDisturb)
        XCTAssertEqual(decision(.blocked, at: date(hour: 7), preferences: overnight), .doNotDisturb)
        XCTAssertEqual(decision(.blocked, at: date(hour: 12), preferences: overnight), .allow)
    }

    func testEventCreatedDuringDNDStaysDroppedAfterWindowEnds() {
        let preferences = PushPreferences(dnd: .init(start: 22 * 60, end: 8 * 60))
        XCTAssertEqual(
            decision(
                .blocked,
                at: date(hour: 9),
                occurredAt: date(hour: 7),
                preferences: preferences
            ),
            .doNotDisturb
        )
    }

    func testDailyWindowUsesThePhoneTimeZone() {
        let preferences = PushPreferences(dnd: .init(
            start: 22 * 60,
            end: 8 * 60,
            timeZoneIdentifier: "Asia/Jerusalem"
        ))

        XCTAssertEqual(
            decision(.blocked, at: date(hour: 20, minute: 30), preferences: preferences),
            .doNotDisturb
        )
    }

    func testDailyWindowUsesEachStoredPhoneTimeZone() {
        let instant = date(hour: 23)
        let jerusalem = PushPreferences(dnd: .init(
            start: 1 * 60,
            end: 4 * 60,
            timeZoneIdentifier: "Asia/Jerusalem"
        ))
        let newYork = PushPreferences(dnd: .init(
            start: 1 * 60,
            end: 4 * 60,
            timeZoneIdentifier: "America/New_York"
        ))

        XCTAssertEqual(decision(.blocked, at: instant, preferences: jerusalem), .doNotDisturb)
        XCTAssertEqual(decision(.blocked, at: instant, preferences: newYork), .allow)
    }

    @MainActor
    func testQueuedAlertIsDroppedWhenDNDStartsBeforeDelivery() async throws {
        _ = NSApplication.shared
        let defaultsName = "PushPreferenceGateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defaults.removePersistentDomain(forName: defaultsName)
        defaults.set(true, forKey: "companionBridgeCredentialMigrationV1")
        defaults.set(true, forKey: "apns.hasKey")
        defaults.set("team", forKey: "apns.teamID")
        defaults.set("key", forKey: "apns.keyID")
        defaults.set("bundle", forKey: "apns.bundleID")
        addTeardownBlock { defaults.removePersistentDomain(forName: defaultsName) }

        let credentialStore = BridgeDeviceCredentialStore(defaults: defaults)
        let client = ClientInfo(
            deviceID: "phone-1",
            name: "Test Phone",
            platform: "iOS",
            model: "iPhone 16"
        )
        let pairingCode = try XCTUnwrap(credentialStore.pairingCode?.value)
        let pairing = try credentialStore.exchange(
            code: pairingCode,
            client: client
        ).get()
        _ = try XCTUnwrap(credentialStore.authenticate(token: pairing.token))
        let preferences = PushPreferences(dnd: .init(start: 13 * 60, end: 14 * 60))
        _ = try XCTUnwrap(credentialStore.updatePushPreferences(
            preferences,
            deviceID: pairing.device.id
        ))

        let registration = TestPushRegistration(
            deviceToken: "test-token",
            environment: "sandbox",
            deviceID: pairing.device.id
        )
        defaults.set(
            try JSONEncoder().encode([registration]),
            forKey: "companionBridgePushRegistrations"
        )

        let queue = APNsDeliveryQueue()
        let blocker = PushQueueGate()
        let blockerStarted = expectation(description: "blocking delivery started")
        var currentTime = date(hour: 12)
        let deliveryCalendar = calendar
        let auditDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rai-push-gate-tests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: auditDirectory) }
        let model = RaiModel(
            client: HerdrClient(socketPath: "/nonexistent/herdr.sock"),
            userDefaults: defaults
        )
        let server = RaiBridgeServer(
            model: model,
            userDefaults: defaults,
            apnsSettings: APNsSettings(defaults: defaults) { ("test-key", errSecSuccess) },
            auditLogURL: auditDirectory.appendingPathComponent("audit.jsonl"),
            pushDeliveryQueue: queue,
            now: { currentTime }
        )
        let burst = PhonePushBurst(events: [PhonePushEvent(
            paneID: "pane-1",
            paneName: "Agent",
            workspaceID: "workspace-1",
            workspaceName: "Work",
            status: .blocked,
            occurredAt: date(hour: 12)
        )])

        let first = queue.enqueue(key: "sandbox:test-token") {
            blockerStarted.fulfill()
            await blocker.wait()
        }
        await fulfillment(of: [blockerStarted], timeout: 1)
        server.sendPush(burst, now: currentTime, calendar: deliveryCalendar)

        currentTime = date(hour: 13, minute: 15)
        await blocker.open()
        await first.value
        for _ in 0..<100 where server.lastPushResult == nil {
            await Task.yield()
        }

        XCTAssertEqual(
            server.lastPushResult,
            "Push dropped by device notification preferences."
        )
    }

    func testEffectivePreferencesRemoveExpiredAndInvalidValues() {
        let now = date(hour: 12)
        let preferences = PushPreferences(
            kinds: .init(needsYou: false, finished: true),
            snoozeUntil: date(hour: 11),
            dnd: .init(start: -1, end: 8 * 60)
        ).effective(at: now)

        XCTAssertEqual(preferences.kinds, .init(needsYou: false, finished: true))
        XCTAssertNil(preferences.snoozeUntil)
        XCTAssertNil(preferences.dnd)
    }

    private func decision(
        _ status: AgentStatus,
        at now: Date,
        occurredAt: Date? = nil,
        preferences: PushPreferences
    ) -> PushPreferenceDecision {
        PushPreferenceGate.evaluate(
            status: status,
            occurredAt: occurredAt ?? now,
            preferences: preferences,
            now: now,
            calendar: calendar
        )
    }

    private func date(hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 3,
            hour: hour,
            minute: minute
        ))!
    }
}

private struct TestPushRegistration: Encodable {
    let deviceToken: String
    let environment: String
    let deviceID: String
}

private actor PushQueueGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
