import AppKit
import SwiftUI

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var terminalFontFamily: String {
        didSet {
            userDefaults.set(terminalFontFamily, forKey: Self.terminalFontFamilyKey)
        }
    }

    @Published var terminalFontSize: Double {
        didSet {
            userDefaults.set(terminalFontSize, forKey: Self.terminalFontSizeKey)
        }
    }

    private static let terminalFontFamilyKey = "terminalFontFamily"
    private static let terminalFontSizeKey = "terminalFontSize"
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        terminalFontFamily = userDefaults.string(forKey: Self.terminalFontFamilyKey)
            ?? "Fira Code"

        let savedSize = userDefaults.object(forKey: Self.terminalFontSizeKey) as? NSNumber
        terminalFontSize = min(max(savedSize?.doubleValue ?? 16, 9), 24)
    }

    var availableFontFamilies: [String] {
        let families = NSFontManager.shared.availableFontFamilies.filter { family in
            NSFontManager.shared.font(
                withFamily: family,
                traits: [],
                weight: 5,
                size: 16
            )?.isFixedPitch == true
        }
        guard !families.contains(terminalFontFamily) else { return families }
        return [terminalFontFamily] + families
    }
}

struct SettingsView: View {
    @ObservedObject var model: CorralModel
    @StateObject private var settings = SettingsStore.shared

    var body: some View {
        TabView {
            AppearanceSettingsView(model: model, settings: settings)
                .tabItem {
                    Label("Appearance", systemImage: "textformat")
                }

            HerdrServerSettingsView(model: model)
                .tabItem {
                    Label("Herdr Server", systemImage: "server.rack")
                }
        }
        .frame(width: 620, height: 460)
        .background(Theme.base)
    }
}

private struct AppearanceSettingsView: View {
    @ObservedObject var model: CorralModel
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection(title: "Terminal") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Font family")
                            .frame(width: 120, alignment: .leading)
                        Picker("", selection: $settings.terminalFontFamily) {
                            ForEach(settings.availableFontFamilies, id: \.self) { family in
                                Text(family).tag(family)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 260)
                    }

                    HStack {
                        Text("Font size")
                            .frame(width: 120, alignment: .leading)
                        Stepper(
                            value: $settings.terminalFontSize,
                            in: 9...24,
                            step: 1
                        ) {
                            Text("\(Int(settings.terminalFontSize)) pt")
                                .monospacedDigit()
                                .frame(width: 48, alignment: .trailing)
                        }
                        .frame(width: 118)
                    }

                    Text("Applies to new terminals.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
            }

            SettingsSection(title: "Notification Defaults") {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("Mute notifications", isOn: $model.notificationsMuted)
                    Toggle("Only needs-you by default", isOn: $model.onlyNeedsYou)
                }
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
            }

            Spacer()
        }
        .settingsTabBackground()
    }
}

private struct HerdrServerSettingsView: View {
    @ObservedObject var model: CorralModel

    @State private var output = "Loading server status…"
    @State private var isRunningAction = false
    @State private var isStopConfirmationPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection(title: "Current Server Status") {
                ScrollView {
                    Text(output)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, minHeight: 210)
            }

            HStack(spacing: 10) {
                Button("Refresh") {
                    Task { await refreshStatus() }
                }
                Button("Reload Config") {
                    Task { await reloadConfig() }
                }
                Button("Update herdr") {
                    Task { await updateHerdr() }
                }
                Spacer()
                Button("Stop Server", role: .destructive) {
                    isStopConfirmationPresented = true
                }
            }
            .buttonStyle(.bordered)
            .disabled(isRunningAction)

            Spacer()
        }
        .settingsTabBackground()
        .task {
            await refreshStatus()
        }
        .alert("Stop Herdr Server?", isPresented: $isStopConfirmationPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Stop Server", role: .destructive) {
                Task { await stopServer() }
            }
        } message: {
            Text("This stops the active Herdr server and its running panes.")
        }
    }

    private func refreshStatus() async {
        isRunningAction = true
        output = await model.serverStatus()
        isRunningAction = false
    }

    private func reloadConfig() async {
        isRunningAction = true
        if await model.reloadConfig() {
            output = await model.serverStatus()
        } else {
            output = "Unable to reload the Herdr server configuration."
        }
        isRunningAction = false
    }

    private func updateHerdr() async {
        isRunningAction = true
        output = await model.updateHerdr()
        isRunningAction = false
    }

    private func stopServer() async {
        isRunningAction = true
        if await model.stopServer() {
            output = "Herdr server stopped."
        } else {
            output = "Unable to stop the Herdr server."
        }
        isRunningAction = false
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            content
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.raised)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Theme.hairlineStrong, lineWidth: 1)
                )
        }
    }
}

private extension View {
    func settingsTabBackground() -> some View {
        padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.base)
    }
}
