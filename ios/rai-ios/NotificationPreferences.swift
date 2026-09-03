import RaiCore
import SwiftUI

@MainActor
final class NotificationPreferencesViewModel: ObservableObject {
    @Published var needsYou = true
    @Published var finished = true
    @Published var snoozeUntil: Date?
    @Published var dndEnabled = false
    @Published var dndStartMinutes = 22 * 60
    @Published var dndEndMinutes = 8 * 60

    private let now: () -> Date
    private let calendar: Calendar

    init(
        preferences: PushPreferences = .default,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current
    ) {
        self.now = now
        self.calendar = calendar
        apply(preferences)
    }

    var preferences: PushPreferences {
        PushPreferences(
            kinds: .init(needsYou: needsYou, finished: finished),
            snoozeUntil: activeSnoozeUntil,
            dnd: dndEnabled
                ? .init(
                    start: dndStartMinutes,
                    end: dndEndMinutes,
                    timeZoneIdentifier: calendar.timeZone.identifier
                )
                : nil
        )
    }

    var activeSnoozeUntil: Date? {
        guard let snoozeUntil, snoozeUntil > now() else { return nil }
        return snoozeUntil
    }

    func apply(_ preferences: PushPreferences) {
        needsYou = preferences.kinds.needsYou
        finished = preferences.kinds.finished
        snoozeUntil = preferences.snoozeUntil
        dndEnabled = preferences.dnd != nil
        dndStartMinutes = preferences.dnd?.start ?? 22 * 60
        dndEndMinutes = preferences.dnd?.end ?? 8 * 60
    }

    func snooze(for interval: TimeInterval) {
        snoozeUntil = now().addingTimeInterval(interval)
    }

    func snoozeUntilTomorrow() {
        let date = now()
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: date),
              let target = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow)
        else { return }
        snoozeUntil = target
    }

    func clearSnooze() {
        snoozeUntil = nil
    }

    func remainingSnooze(at date: Date) -> String? {
        guard let until = activeSnoozeUntil else { return nil }
        let seconds = max(0, Int(until.timeIntervalSince(date)))
        if seconds >= 3_600 {
            let hours = seconds / 3_600
            let minutes = (seconds % 3_600) / 60
            return "\(hours)h \(minutes)m remaining"
        }
        return "\(max(1, seconds / 60))m remaining"
    }
}

struct NotificationPreferencesSheet: View {
    @ObservedObject var connection: BridgeConnection
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: NotificationPreferencesViewModel

    init(connection: BridgeConnection) {
        self.connection = connection
        _model = StateObject(wrappedValue: NotificationPreferencesViewModel(
            preferences: connection.pendingPushPreferences ?? connection.pushPreferences
        ))
    }

    var body: some View {
        NavigationStack {
            Form {
                if let syncStatus = connection.pushPreferencesSyncStatus {
                    Section {
                        LabeledContent("Sync", value: syncStatus)
                    }
                }
                Section("Kinds") {
                    Toggle("Needs you", isOn: $model.needsYou)
                    Toggle("Finished", isOn: $model.finished)
                }

                Section("Snooze") {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        if let remaining = model.remainingSnooze(at: context.date) {
                            LabeledContent("Status", value: remaining)
                        } else {
                            LabeledContent("Status", value: "Off")
                        }
                    }
                    HStack {
                        Button("15 min") { model.snooze(for: 15 * 60) }
                        Spacer()
                        Button("1 hour") { model.snooze(for: 60 * 60) }
                        Spacer()
                        Button("Tomorrow 08:00") { model.snoozeUntilTomorrow() }
                    }
                    if model.activeSnoozeUntil != nil {
                        Button("End Snooze", role: .destructive) {
                            model.clearSnooze()
                        }
                    }
                }

                Section("Daily Do Not Disturb") {
                    Toggle("Use a daily window", isOn: $model.dndEnabled)
                    if model.dndEnabled {
                        DatePicker(
                            "Start",
                            selection: minuteBinding($model.dndStartMinutes),
                            displayedComponents: .hourAndMinute
                        )
                        DatePicker(
                            "End",
                            selection: minuteBinding($model.dndEndMinutes),
                            displayedComponents: .hourAndMinute
                        )
                    }
                }
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onDisappear(perform: save)
        }
    }

    private func save() {
        connection.setPushPreferences(model.preferences)
    }

    private func minuteBinding(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: minutes.wrappedValue / 60,
                    minute: minutes.wrappedValue % 60,
                    second: 0,
                    of: Date()
                ) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }
}
