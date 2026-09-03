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
    func testUnconfirmedWriteDoesNotReplaceStoredState() {
        let connection = BridgeConnection()
        let proposed = PushPreferences(kinds: .init(needsYou: false, finished: true))

        connection.setPushPreferences(proposed)

        XCTAssertEqual(connection.pushPreferences, .default)
        XCTAssertEqual(
            connection.actionError,
            "Update Rai on the Mac to change notification settings."
        )
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
