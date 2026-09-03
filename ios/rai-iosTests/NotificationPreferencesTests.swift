import Foundation
import RaiCore
import XCTest

@testable import rai

final class NotificationPreferencesTests: XCTestCase {
    @MainActor
    func testViewModelEditsAndRestoresEffectivePreferences() {
        let now = date(hour: 12)
        let model = NotificationPreferencesViewModel(
            preferences: .default,
            now: { now },
            calendar: calendar
        )

        model.needsYou = false
        model.finished = true
        model.dndEnabled = true
        model.dndStartMinutes = 21 * 60
        model.dndEndMinutes = 7 * 60
        model.snooze(for: 15 * 60)

        XCTAssertEqual(model.preferences.kinds, .init(needsYou: false, finished: true))
        XCTAssertEqual(model.preferences.snoozeUntil, now.addingTimeInterval(15 * 60))
        XCTAssertEqual(
            model.preferences.dnd,
            .init(start: 21 * 60, end: 7 * 60, timeZoneIdentifier: "GMT")
        )

        model.apply(.default)
        XCTAssertTrue(model.needsYou)
        XCTAssertTrue(model.finished)
        XCTAssertFalse(model.dndEnabled)
        XCTAssertNil(model.activeSnoozeUntil)
    }

    @MainActor
    func testTomorrowSnoozeTargetsEightInTheMorning() throws {
        let now = date(hour: 23, minute: 30)
        let model = NotificationPreferencesViewModel(
            now: { now },
            calendar: calendar
        )

        model.snoozeUntilTomorrow()

        let target = try XCTUnwrap(model.snoozeUntil)
        let parts = calendar.dateComponents([.day, .hour, .minute], from: target)
        XCTAssertEqual(parts.day, 4)
        XCTAssertEqual(parts.hour, 8)
        XCTAssertEqual(parts.minute, 0)
    }

    @MainActor
    func testDisconnectedWritePersistsAndSendsOnWelcomeUntilConfirmed() async throws {
        let defaultsName = "NotificationPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defaults.removePersistentDomain(forName: defaultsName)
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let proposed = PushPreferences(kinds: .init(needsYou: false, finished: true))
        let sentPreferences = expectation(description: "pending preferences sent")
        let connection = BridgeConnection(
            userDefaults: defaults,
            messageSender: { message in
                if case let .pushPrefs(preferences) = message,
                   preferences == proposed {
                    sentPreferences.fulfill()
                }
            }
        )
        connection.handle(.pushPrefsState(.default))
        connection.scheduleReconnect(after: URLError(.networkConnectionLost))

        connection.setPushPreferences(proposed)

        XCTAssertEqual(connection.pushPreferences, .default)
        XCTAssertEqual(connection.pendingPushPreferences, proposed)
        XCTAssertEqual(connection.pushPreferencesSyncStatus, "Pending")
        XCTAssertEqual(
            BridgeConnection(userDefaults: defaults).pendingPushPreferences,
            proposed
        )

        connection.finishAuthentication(
            protocolVersion: bridgeProtocolVersion,
            sessionName: nil
        )
        await fulfillment(of: [sentPreferences], timeout: 1)
        XCTAssertEqual(connection.pendingPushPreferences, proposed)

        connection.handle(.pushPrefsState(proposed))

        XCTAssertNil(connection.pendingPushPreferences)
        XCTAssertNil(connection.pushPreferencesSyncStatus)
        XCTAssertNil(BridgeConnection(userDefaults: defaults).pendingPushPreferences)
    }

    func testTimeZoneSyncKeepsWallClockMinutesAndUsesCurrentZone() throws {
        let original = PushPreferences(dnd: .init(
            start: 22 * 60,
            end: 8 * 60,
            timeZoneIdentifier: "Asia/Jerusalem"
        ))

        let newYork = PushPreferencesTimeZoneSync.applyingCurrentZone(
            to: original,
            timeZone: try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        )
        let tokyo = PushPreferencesTimeZoneSync.applyingCurrentZone(
            to: newYork,
            timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        )

        XCTAssertEqual(newYork.dnd?.start, 22 * 60)
        XCTAssertEqual(newYork.dnd?.end, 8 * 60)
        XCTAssertEqual(newYork.dnd?.timeZoneIdentifier, "America/New_York")
        XCTAssertEqual(tokyo.dnd?.start, 22 * 60)
        XCTAssertEqual(tokyo.dnd?.end, 8 * 60)
        XCTAssertEqual(tokyo.dnd?.timeZoneIdentifier, "Asia/Tokyo")
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
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
