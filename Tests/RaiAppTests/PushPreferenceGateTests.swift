import Foundation
import RaiCore
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
