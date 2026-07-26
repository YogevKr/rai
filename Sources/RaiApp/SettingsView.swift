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

    @Published var appearanceMode: AppearanceMode {
        didSet {
            userDefaults.set(appearanceMode.rawValue, forKey: Self.appearanceModeKey)
        }
    }

    @Published private(set) var colorOverrides: [ThemeVariant: [ThemeColorRole: RGBAColor]] {
        didSet { persistColorOverrides() }
    }

    @Published var blockedNotificationSound: NotificationSoundChoice {
        didSet {
            userDefaults.set(blockedNotificationSound.rawValue, forKey: Self.blockedSoundKey)
        }
    }

    @Published var doneNotificationSound: NotificationSoundChoice {
        didSet {
            userDefaults.set(doneNotificationSound.rawValue, forKey: Self.doneSoundKey)
        }
    }

    @Published private(set) var systemThemeVariant: ThemeVariant

    private static let terminalFontFamilyKey = "terminalFontFamily"
    private static let terminalFontSizeKey = "terminalFontSize"
    private static let appearanceModeKey = "appearanceMode"
    private static let colorOverridesKey = "themeColorOverrides"
    private static let blockedSoundKey = "blockedNotificationSound"
    private static let doneSoundKey = "doneNotificationSound"
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        terminalFontFamily = userDefaults.string(forKey: Self.terminalFontFamilyKey)
            ?? "Fira Code"

        let savedSize = userDefaults.object(forKey: Self.terminalFontSizeKey) as? NSNumber
        terminalFontSize = min(max(savedSize?.doubleValue ?? 16, 9), 24)
        appearanceMode = AppearanceMode(
            rawValue: userDefaults.string(forKey: Self.appearanceModeKey) ?? ""
        ) ?? .dark
        blockedNotificationSound = NotificationSoundChoice(
            rawValue: userDefaults.string(forKey: Self.blockedSoundKey) ?? ""
        ) ?? .default
        doneNotificationSound = NotificationSoundChoice(
            rawValue: userDefaults.string(forKey: Self.doneSoundKey) ?? ""
        ) ?? .default
        colorOverrides = Self.loadColorOverrides(
            from: userDefaults.data(forKey: Self.colorOverridesKey)
        )
        systemThemeVariant = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            == .darkAqua ? .dark : .light
    }

    var activeThemeVariant: ThemeVariant {
        switch appearanceMode {
        case .light: .light
        case .dark: .dark
        case .system: systemThemeVariant
        }
    }

    func updateSystemColorScheme(_ colorScheme: ColorScheme) {
        let variant: ThemeVariant = colorScheme == .dark ? .dark : .light
        guard systemThemeVariant != variant else { return }
        systemThemeVariant = variant
    }

    func resolvedColor(_ role: ThemeColorRole, for theme: ThemeVariant) -> RGBAColor {
        colorOverrides[theme]?[role] ?? defaultPalette(for: theme)[role]
    }

    func setColor(_ color: Color, role: ThemeColorRole, for theme: ThemeVariant) {
        guard let rgba = RGBAColor(color: color) else { return }
        colorOverrides[theme, default: [:]][role] = rgba
    }

    func resetColors(for theme: ThemeVariant) {
        colorOverrides[theme] = nil
    }

    private func defaultPalette(for theme: ThemeVariant) -> ThemePalette {
        theme == .dark ? .dark : .light
    }

    private func persistColorOverrides() {
        let encoded = colorOverrides.reduce(into: [String: [String: RGBAColor]]()) {
            $0[$1.key.rawValue] = $1.value.reduce(into: [:]) {
                $0[$1.key.rawValue] = $1.value
            }
        }
        if let data = try? JSONEncoder().encode(encoded) {
            userDefaults.set(data, forKey: Self.colorOverridesKey)
        }
    }

    private static func loadColorOverrides(
        from data: Data?
    ) -> [ThemeVariant: [ThemeColorRole: RGBAColor]] {
        guard let data,
              let decoded = try? JSONDecoder().decode(
                  [String: [String: RGBAColor]].self,
                  from: data
              ) else {
            return [:]
        }
        return decoded.reduce(into: [:]) { themes, item in
            guard let theme = ThemeVariant(rawValue: item.key) else { return }
            themes[theme] = item.value.reduce(into: [:]) { roles, item in
                guard let role = ThemeColorRole(rawValue: item.key) else { return }
                roles[role] = item.value
            }
        }
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

enum NotificationSoundChoice: RawRepresentable, Hashable {
    case `default`
    case none
    case named(String)

    init?(rawValue: String) {
        switch rawValue {
        case "default": self = .default
        case "none": self = .none
        default:
            guard rawValue.hasPrefix("named:") else { return nil }
            self = .named(String(rawValue.dropFirst(6)))
        }
    }

    var rawValue: String {
        switch self {
        case .default: "default"
        case .none: "none"
        case let .named(name): "named:\(name)"
        }
    }

    var label: String {
        switch self {
        case .default: "Default"
        case .none: "None"
        case let .named(name): name
        }
    }

    static var available: [Self] {
        let directory = URL(fileURLWithPath: "/System/Library/Sounds")
        let names = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ))?
            .filter { $0.pathExtension.lowercased() == "aiff" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
            ?? []
        return [.default, .none] + names.map(Self.named)
    }

    func playSample() {
        switch self {
        case .none:
            break
        case .default:
            NSSound.beep()
        case let .named(name):
            NSSound(named: NSSound.Name(name))?.play()
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: RaiModel
    @StateObject private var settings = SettingsStore.shared
    @Environment(\.colorScheme) private var colorScheme

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

            PluginsSettingsView(model: model)
                .tabItem {
                    Label("Plugins", systemImage: "puzzlepiece.extension")
                }

            IntegrationsSettingsView(model: model)
                .tabItem {
                    Label(
                        "Integrations",
                        systemImage: "app.connected.to.app.below.fill"
                    )
                }

            ConfigSettingsView(model: model)
                .tabItem {
                    Label("Config", systemImage: "doc.text")
                }
        }
        .frame(width: 680, height: 640)
        .background(Theme.base)
        .onAppear { settings.updateSystemColorScheme(colorScheme) }
        .onChange(of: colorScheme) { _, value in
            settings.updateSystemColorScheme(value)
        }
    }
}

private struct AppearanceSettingsView: View {
    @ObservedObject var model: RaiModel
    @ObservedObject var settings: SettingsStore
    @State private var customizedTheme: ThemeVariant = .dark

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsSection(title: "Theme") {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("Mode", selection: $settings.appearanceMode) {
                            ForEach(AppearanceMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 360)

                        HStack {
                            Picker("Customize", selection: $customizedTheme) {
                                ForEach(ThemeVariant.allCases) { theme in
                                    Text(theme.label).tag(theme)
                                }
                            }
                            .frame(width: 220)
                            Spacer()
                            Button("Reset \(customizedTheme.label) to Defaults") {
                                settings.resetColors(for: customizedTheme)
                            }
                        }

                        HStack(alignment: .top, spacing: 28) {
                            colorGroup(
                                "Core",
                                roles: [.accent, .base, .sidebar, .raised, .bar, .terminalBG]
                            )
                            colorGroup(
                                "Text & Lines",
                                roles: [.textPrimary, .textSecondary, .textTertiary, .hairline]
                            )
                            colorGroup(
                                "Status",
                                roles: [
                                    .statusWorking, .statusBlocked, .statusDone,
                                    .statusIdle, .statusUnknown,
                                ]
                            )
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary)
                }

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

                        Text("Font changes apply to new terminals. Colors apply immediately.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary)
                }

                SettingsSection(title: "Notifications") {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("Mute notifications", isOn: $model.notificationsMuted)
                        Toggle("Only needs-you by default", isOn: $model.onlyNeedsYou)
                        Divider().overlay(Theme.hairline)
                        soundPicker(
                            "Needs you",
                            selection: $settings.blockedNotificationSound
                        )
                        soundPicker(
                            "Done",
                            selection: $settings.doneNotificationSound
                        )
                    }
                    .toggleStyle(.switch)
                    .tint(Theme.accent)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary)
                }
            }
            .padding(22)
        }
        .background(Theme.base)
    }

    private func colorGroup(_ title: String, roles: [ThemeColorRole]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            ForEach(roles) { role in
                ColorPicker(
                    role.label,
                    selection: Binding(
                        get: {
                            settings.resolvedColor(role, for: customizedTheme).color
                        },
                        set: {
                            settings.setColor($0, role: role, for: customizedTheme)
                        }
                    ),
                    supportsOpacity: role == .hairline
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func soundPicker(
        _ title: String,
        selection: Binding<NotificationSoundChoice>
    ) -> some View {
        HStack {
            Text(title)
                .frame(width: 120, alignment: .leading)
            Picker("", selection: selection) {
                ForEach(NotificationSoundChoice.available, id: \.self) { sound in
                    Text(sound.label).tag(sound)
                }
            }
            .labelsHidden()
            .frame(width: 220)
            Button {
                selection.wrappedValue.playSample()
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .help("Play sample")
            .disabled(selection.wrappedValue == .none)
        }
    }
}

private struct HerdrServerSettingsView: View {
    @ObservedObject var model: RaiModel

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

private struct PluginListResponse: Decodable {
    let result: Result

    struct Result: Decodable {
        let plugins: [Plugin]
    }

    struct Plugin: Decodable, Identifiable {
        let pluginID: String
        let name: String
        let description: String
        var enabled: Bool
        let events: [Event]

        var id: String { pluginID }

        private enum CodingKeys: String, CodingKey {
            case pluginID = "plugin_id"
            case name
            case description
            case enabled
            case events
        }
    }

    struct Event: Decodable {
        let on: String
    }
}

private struct PluginsSettingsView: View {
    @ObservedObject var model: RaiModel

    @State private var plugins: [PluginListResponse.Plugin] = []
    @State private var isLoading = false
    @State private var activePluginIDs: Set<String> = []
    @State private var status: String?
    @State private var pluginPendingUnlink: PluginListResponse.Plugin?
    @State private var pluginForLogs: PluginListResponse.Plugin?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Manage plugins linked to this Herdr installation.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button("Refresh") {
                    Task { await refreshPlugins() }
                }
                .buttonStyle(.bordered)
                .disabled(isLoading || !activePluginIDs.isEmpty)
            }

            SettingsSection(title: "Installed Plugins") {
                Group {
                    if isLoading && plugins.isEmpty {
                        HStack(spacing: 9) {
                            ProgressView().controlSize(.small)
                            Text("Loading plugins…")
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 230)
                    } else if plugins.isEmpty {
                        Text(status ?? "No linked plugins.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 230)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(plugins) { plugin in
                                    PluginSettingsRow(
                                        plugin: plugin,
                                        isRunningAction: activePluginIDs.contains(plugin.id),
                                        onEnabledChange: { enabled in
                                            setEnabled(enabled, for: plugin)
                                        },
                                        onLogs: {
                                            pluginForLogs = plugin
                                        },
                                        onUnlink: {
                                            pluginPendingUnlink = plugin
                                        }
                                    )

                                    if plugin.id != plugins.last?.id {
                                        Divider()
                                            .overlay(Theme.hairlineStrong)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 230)
                    }
                }
                .font(.system(size: 12))
            }

            if let status, !plugins.isEmpty {
                Text(status)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
        }
        .settingsTabBackground()
        .task {
            await refreshPlugins()
        }
        .alert(
            "Unlink \(pluginPendingUnlink?.name ?? "Plugin")?",
            isPresented: Binding(
                get: { pluginPendingUnlink != nil },
                set: { if !$0 { pluginPendingUnlink = nil } }
            ),
            presenting: pluginPendingUnlink
        ) { plugin in
            Button("Cancel", role: .cancel) {}
            Button("Unlink", role: .destructive) {
                Task { await unlink(plugin) }
            }
        } message: { plugin in
            Text("This unlinks \(plugin.pluginID) from Herdr.")
        }
        .sheet(item: $pluginForLogs) { plugin in
            PluginLogsSheet(model: model, plugin: plugin)
        }
    }

    private func refreshPlugins() async {
        isLoading = true
        defer { isLoading = false }

        guard let output = await model.pluginList(),
              let data = output.data(using: .utf8) else {
            status = "Unable to list Herdr plugins."
            return
        }

        do {
            plugins = try JSONDecoder()
                .decode(PluginListResponse.self, from: data)
                .result
                .plugins
            status = plugins.isEmpty ? "No linked plugins." : nil
        } catch {
            status = "Unable to decode the Herdr plugin list: \(error.localizedDescription)"
        }
    }

    private func setEnabled(
        _ enabled: Bool,
        for plugin: PluginListResponse.Plugin
    ) {
        guard let index = plugins.firstIndex(where: { $0.id == plugin.id }) else {
            return
        }
        plugins[index].enabled = enabled
        activePluginIDs.insert(plugin.id)
        Task {
            let succeeded = enabled
                ? await model.pluginEnable(plugin.pluginID)
                : await model.pluginDisable(plugin.pluginID)
            if succeeded {
                status = "\(plugin.name) \(enabled ? "enabled" : "disabled")."
            } else {
                if let currentIndex = plugins.firstIndex(where: { $0.id == plugin.id }) {
                    plugins[currentIndex].enabled = !enabled
                }
                status = "Unable to \(enabled ? "enable" : "disable") \(plugin.name)."
            }
            activePluginIDs.remove(plugin.id)
        }
    }

    private func unlink(_ plugin: PluginListResponse.Plugin) async {
        pluginPendingUnlink = nil
        activePluginIDs.insert(plugin.id)
        if await model.pluginUnlink(plugin.pluginID) {
            plugins.removeAll { $0.id == plugin.id }
            status = "\(plugin.name) unlinked."
        } else {
            status = "Unable to unlink \(plugin.name)."
        }
        activePluginIDs.remove(plugin.id)
    }
}

private struct PluginSettingsRow: View {
    let plugin: PluginListResponse.Plugin
    let isRunningAction: Bool
    let onEnabledChange: (Bool) -> Void
    let onLogs: () -> Void
    let onUnlink: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(plugin.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(plugin.pluginID)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Text(plugin.enabled ? "Enabled" : "Disabled")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(
                        plugin.enabled ? Theme.accent : Theme.textTertiary
                    )
                Toggle(
                    "",
                    isOn: Binding(
                        get: { plugin.enabled },
                        set: onEnabledChange
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .controlSize(.small)
                .disabled(isRunningAction)
            }

            Text(plugin.description)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if !plugin.events.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        ForEach(plugin.events.map(\.on), id: \.self) { event in
                            Text(event)
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule()
                                        .fill(Theme.base)
                                )
                                .overlay(
                                    Capsule()
                                        .stroke(Theme.hairlineStrong, lineWidth: 1)
                                )
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            HStack(spacing: 8) {
                Button("Logs", action: onLogs)
                Button("Unlink", role: .destructive, action: onUnlink)
                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isRunningAction)
        }
        .padding(.vertical, 12)
    }
}

private struct PluginLogsSheet: View {
    @ObservedObject var model: RaiModel
    let plugin: PluginListResponse.Plugin

    @Environment(\.dismiss) private var dismiss
    @State private var output = "Loading plugin logs…"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Plugin Logs")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(plugin.pluginID)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Close")
            }

            ScrollView {
                Text(output)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(22)
        .frame(width: 560, height: 380)
        .background(Theme.raised)
        .task {
            output = await model.pluginLogs(plugin.pluginID)
                ?? "No plugin log output."
        }
    }
}

private struct IntegrationsSettingsView: View {
    @ObservedObject var model: RaiModel

    @State private var activeIntegration: String?
    @State private var status = "No integration command run yet."

    private let integrations = [
        "pi", "omp", "claude", "codex", "copilot", "devin", "droid",
        "kimi", "opencode", "kilo", "hermes", "qodercli", "cursor",
        "mastracode",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Install and uninstall are idempotent; Herdr does not report integration state.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)

            SettingsSection(title: "Agent Integrations") {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(integrations, id: \.self) { integration in
                            HStack(spacing: 10) {
                                Text(integration)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                                Button("Install") {
                                    Task {
                                        await runIntegrationAction(
                                            integration,
                                            install: true
                                        )
                                    }
                                }
                                Button("Uninstall", role: .destructive) {
                                    Task {
                                        await runIntegrationAction(
                                            integration,
                                            install: false
                                        )
                                    }
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .padding(.vertical, 7)
                            .disabled(activeIntegration != nil)

                            if integration != integrations.last {
                                Divider()
                                    .overlay(Theme.hairlineStrong)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 230)
            }

            Text(status)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .settingsTabBackground()
    }

    private func runIntegrationAction(
        _ integration: String,
        install: Bool
    ) async {
        activeIntegration = integration
        status = "\(install ? "Installing" : "Uninstalling") \(integration)…"
        let output = install
            ? await model.integrationInstall(integration)
            : await model.integrationUninstall(integration)
        status = output
            ?? "\(install ? "Install" : "Uninstall") for \(integration) failed or returned no output."
        activeIntegration = nil
    }
}

private struct ConfigSettingsView: View {
    @ObservedObject var model: RaiModel

    @State private var configText = ""
    @State private var status: String?
    @State private var fileExists = true
    @State private var isRunningAction = false

    private var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/herdr/config.toml")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Caution: this edits the shared global Herdr configuration.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)

            SettingsSection(title: "~/.config/herdr/config.toml") {
                VStack(alignment: .leading, spacing: 9) {
                    if !fileExists {
                        Text("The config file does not exist yet. Saving will create it.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.textTertiary)
                    }

                    TextEditor(text: $configText)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Theme.base)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Theme.hairlineStrong, lineWidth: 1)
                        )
                        .frame(minHeight: 160)
                }
            }

            HStack(spacing: 10) {
                Button("Check") {
                    Task { await checkConfig() }
                }
                Button("Save", action: saveConfig)
                Button("Reload Server") {
                    Task { await reloadServer() }
                }
                Spacer()
            }
            .buttonStyle(.bordered)
            .disabled(isRunningAction)

            if let status {
                ScrollView {
                    Text(status)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxHeight: 44)
            }
        }
        .settingsTabBackground()
        .task {
            loadConfig()
        }
    }

    private func loadConfig() {
        do {
            configText = try String(contentsOf: configURL, encoding: .utf8)
            fileExists = true
            status = nil
        } catch CocoaError.fileReadNoSuchFile {
            configText = ""
            fileExists = false
            status = nil
        } catch {
            configText = ""
            fileExists = FileManager.default.fileExists(atPath: configURL.path)
            status = "Unable to load config: \(error.localizedDescription)"
        }
    }

    private func saveConfig() {
        do {
            try FileManager.default.createDirectory(
                at: configURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try configText.write(to: configURL, atomically: true, encoding: .utf8)
            fileExists = true
            status = "Config saved."
        } catch {
            status = "Unable to save config: \(error.localizedDescription)"
        }
    }

    private func checkConfig() async {
        isRunningAction = true
        status = await model.configCheck()
            ?? "Config check failed or returned no diagnostics."
        isRunningAction = false
    }

    private func reloadServer() async {
        isRunningAction = true
        status = await model.reloadConfig()
            ? "Herdr server configuration reloaded."
            : "Unable to reload the Herdr server configuration."
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
