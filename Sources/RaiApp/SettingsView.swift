import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import RaiCore
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

    /// herdr-style copy gesture: finishing a drag-selection copies it and
    /// clears the highlight. Off (default) = Ghostty-style: the selection
    /// stays until you copy explicitly or click elsewhere.
    @Published var copyOnSelect: Bool {
        didSet {
            userDefaults.set(copyOnSelect, forKey: Self.copyOnSelectKey)
        }
    }

    /// On (default): phone pushes are held while the user is active at the
    /// Mac and fire only if the pane still wants attention once they step
    /// away. Off: push immediately, presence ignored.
    @Published var holdPushesWhileAtMac: Bool {
        didSet {
            userDefaults.set(holdPushesWhileAtMac, forKey: Self.holdPushesKey)
        }
    }

    @Published var answerFromPhone: Bool {
        didSet {
            userDefaults.set(answerFromPhone, forKey: Self.answerFromPhoneKey)
        }
    }

    @Published var answerFromPhoneHoldSeconds: Int {
        didSet {
            let value = Self.clampedDecisionHoldSeconds(answerFromPhoneHoldSeconds)
            if value != answerFromPhoneHoldSeconds {
                answerFromPhoneHoldSeconds = value
            }
            userDefaults.set(value, forKey: Self.answerFromPhoneHoldSecondsKey)
        }
    }

    @Published private(set) var systemThemeVariant: ThemeVariant

    private static let terminalFontFamilyKey = "terminalFontFamily"
    private static let terminalFontSizeKey = "terminalFontSize"
    private static let appearanceModeKey = "appearanceMode"
    private static let colorOverridesKey = "themeColorOverrides"
    private static let blockedSoundKey = "blockedNotificationSound"
    private static let doneSoundKey = "doneNotificationSound"
    private static let copyOnSelectKey = "terminalCopyOnSelect"
    private static let holdPushesKey = "holdPushesWhileAtMac"
    static let answerFromPhoneKey = "answerFromPhone"
    static let answerFromPhoneHoldSecondsKey = "answerFromPhoneHoldSeconds"
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
        copyOnSelect = userDefaults.bool(forKey: Self.copyOnSelectKey)
        holdPushesWhileAtMac = userDefaults.object(forKey: Self.holdPushesKey) as? Bool ?? true
        answerFromPhone = userDefaults.object(forKey: Self.answerFromPhoneKey) as? Bool ?? true
        answerFromPhoneHoldSeconds = Self.clampedDecisionHoldSeconds(
            userDefaults.object(forKey: Self.answerFromPhoneHoldSecondsKey) as? Int
                ?? ClaudeHookSettings.defaultDecisionHoldSeconds
        )
        colorOverrides = Self.loadColorOverrides(
            from: userDefaults.data(forKey: Self.colorOverridesKey)
        )
        systemThemeVariant = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            == .darkAqua ? .dark : .light
    }

    static func clampedDecisionHoldSeconds(_ value: Int) -> Int {
        ClaudeHookSettings.clampedDecisionHoldSeconds(value)
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

            CompanionSettingsView(model: model)
                .tabItem {
                    Label("iPhone", systemImage: "iphone")
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

            CodexMicroSettingsView()
                .tabItem {
                    Label("Codex Micro", systemImage: "keyboard.badge.ellipsis")
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

private struct CompanionSettingsView: View {
    @ObservedObject private var server: RaiBridgeServer
    @ObservedObject private var apnsSettings: APNsSettings
    @ObservedObject private var presenceStatus = PushPresenceStatus.shared
    @State private var keyP8Draft: String
    @State private var keyP8Error: String?

    init(model: RaiModel) {
        server = model.bridgeServer
        apnsSettings = model.bridgeServer.apnsSettings
        _keyP8Draft = State(initialValue: model.bridgeServer.apnsSettings.keyP8)
    }

    /// APNs push is a self-hoster feature — it needs your own Apple Developer
    /// account and your own iOS build — so it's noise for most users. Hide the
    /// section by default; show it only when it's already configured, or when
    /// explicitly revealed with
    /// `defaults write gr.krig.rai companionPushSettingsVisible -bool true`.
    private var showPushSettings: Bool {
        apnsSettings.isConfigured
            || apnsSettings.keyReadState == .unreadable
            || UserDefaults.standard.bool(forKey: "companionPushSettingsVisible")
    }

    private var doctorFindings: [DoctorFinding] {
        CompanionDoctor.findings(for: CompanionDoctorState(
            bridgeEnabled: server.isEnabled,
            bridgeListening: server.isRunning,
            bonjourAdvertised: server.isBonjourAdvertised,
            bridgePort: server.port,
            tailscaleState: server.tailscaleServeState,
            tailscaleURL: server.tailscaleWSSURL?.absoluteString,
            apnsKeyState: apnsSettings.keyReadState,
            apnsEnvironment: apnsSettings.defaultEnvironment,
            registeredDeviceCount: server.registeredPushDeviceCount,
            presenceGateEnabled: SettingsStore.shared.holdPushesWhileAtMac,
            presenceGateIsAway: presenceStatus.isAway,
            pendingPushCount: presenceStatus.pendingCount,
            lastPushResult: server.lastPushResult,
            lastPushSucceeded: server.lastPushSucceeded,
            devicePreferences: server.pairedDevices.map {
                DoctorDevicePreferences(
                    id: $0.id,
                    label: $0.label,
                    preferences: $0.pushPreferences.effective(at: Date())
                )
            }
        ))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsSection(title: "Companion Bridge") {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(
                        "Allow iPhone connections",
                        isOn: Binding(
                            get: { server.isEnabled },
                            set: { server.isEnabled = $0 }
                        )
                    )
                    .toggleStyle(.switch)

                    Text(
                        "Each phone gets its own credential over WebSocket. "
                            + "Connect only over a trusted LAN or Tailscale network."
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)

                    if server.isEnabled {
                        Divider().overlay(Theme.hairline)
                        VStack(alignment: .leading, spacing: 16) {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                if let code = server.pairingCode,
                                   let expiry = server.pairingCodeExpiresAt,
                                   expiry > context.date {
                                    VStack(alignment: .leading, spacing: 14) {
                                        companionValue(label: "Pairing code", value: code)
                                        Text("Expires in \(remainingTime(until: expiry, now: context.date))")
                                            .font(.system(size: 11))
                                            .foregroundStyle(Theme.textTertiary)
                                        HStack(alignment: .top, spacing: 24) {
                                            pairingOption(
                                                title: "Same Wi-Fi",
                                                address: "\(server.displayHost):\(server.port)",
                                                url: server.pairingURL
                                            )
                                            if let host = server.tailscaleHost {
                                                pairingOption(
                                                    title: "Anywhere via Tailscale",
                                                    address: "\(host):\(server.tailscalePort)",
                                                    url: server.tailscalePairingURL
                                                )
                                            }
                                        }
                                    }
                                } else {
                                    Text("The pairing code expired or was used.")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.textTertiary)
                                }
                            }

                            Button("New Pairing Code") {
                                server.regeneratePairingCode()
                            }

                            companionValue(
                                label: "Connected",
                                value: "\(server.connectedDeviceCount) device"
                                    + (server.connectedDeviceCount == 1 ? "" : "s")
                            )
                            if let status = server.statusMessage {
                                Text(status)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.status(.blocked))
                            } else if server.isRunning {
                                Text("Listening and advertised as _rai._tcp.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.status(.done))
                            } else {
                                Text("Starting bridge…")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
                }

                SettingsSection(title: "Paired Devices") {
                    VStack(alignment: .leading, spacing: 12) {
                        if server.pairedDevices.isEmpty {
                            Text("No phones are paired.")
                                .foregroundStyle(Theme.textTertiary)
                        } else {
                            ForEach(server.pairedDevices) { device in
                                HStack(alignment: .top, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(device.label)
                                            .foregroundStyle(Theme.textPrimary)
                                        Text("Paired \(device.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                        Text("Last seen \(device.lastSeen.formatted(date: .abbreviated, time: .shortened))")
                                    }
                                    .foregroundStyle(Theme.textTertiary)
                                    Spacer()
                                    Button("Revoke", role: .destructive) {
                                        server.revokeDevice(id: device.id)
                                    }
                                }
                                if device.id != server.pairedDevices.last?.id {
                                    Divider().overlay(Theme.hairline)
                                }
                            }
                        }
                        Button("Show audit log") {
                            NSWorkspace.shared.activateFileViewerSelecting([server.auditLogURL])
                        }
                    }
                    .font(.system(size: 12))
                }

                if showPushSettings {
                SettingsSection(title: "Push Notifications") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            pushField("Team ID", text: $apnsSettings.teamID)
                            pushField("Key ID", text: $apnsSettings.keyID)
                        }
                        HStack(spacing: 12) {
                            pushField("Bundle ID", text: $apnsSettings.bundleID)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Default environment")
                                    .foregroundStyle(Theme.textTertiary)
                                Picker("", selection: $apnsSettings.defaultEnvironment) {
                                    Text("Sandbox").tag("sandbox")
                                    Text("Production").tag("production")
                                }
                                .labelsHidden()
                            }
                        }
                        Text("APNs Auth Key (.p8 PEM)")
                            .foregroundStyle(Theme.textTertiary)
                        TextEditor(text: $keyP8Draft)
                            .font(.system(size: 10.5, design: .monospaced))
                            .frame(height: 100)
                            .scrollContentBackground(.hidden)
                            .padding(5)
                            .background(Theme.raised)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Theme.hairline)
                            }
                        HStack {
                            Button("Save Auth Key") {
                                do {
                                    try apnsSettings.setKeyP8(keyP8Draft)
                                    keyP8Error = nil
                                } catch {
                                    keyP8Error = error.localizedDescription
                                }
                            }
                            Text(
                                apnsSettings.isConfigured
                                    ? "Configured · \(server.registeredPushDeviceCount) device(s) registered"
                                    : "Not configured"
                            )
                            .foregroundStyle(
                                apnsSettings.isConfigured
                                    ? Theme.status(.done)
                                    : Theme.textTertiary
                            )
                            if let keyP8Error {
                                Text(keyP8Error)
                                    .foregroundStyle(Theme.status(.blocked))
                            }
                            if apnsSettings.canRetryLegacyKeyMigration {
                                Button("Retry Migration") {
                                    apnsSettings.retryLegacyKeyMigration()
                                    keyP8Draft = apnsSettings.keyP8
                                }
                            }
                        }
                        HStack {
                            Text(apnsSettings.keyFileURL.path)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Theme.textTertiary)
                                .textSelection(.enabled)
                            Spacer()
                            Button("Reveal") {
                                let target = apnsSettings.hasStoredKey
                                    ? apnsSettings.keyFileURL
                                    : apnsSettings.keyFileURL.deletingLastPathComponent()
                                NSWorkspace.shared.activateFileViewerSelecting([target])
                            }
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary)
                }
                }

                SettingsSection(title: "Push Test") {
                    VStack(alignment: .leading, spacing: 10) {
                        Button(server.isSendingTestPush ? "Sending…" : "Send test push") {
                            server.sendTestPush()
                        }
                        .disabled(server.isSendingTestPush)

                        ForEach(server.testPushResults) { result in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Circle()
                                    .fill(result.succeeded ? Color.green : Color.red)
                                    .frame(width: 7, height: 7)
                                Text("\(result.deviceLabel) · \(result.environment)")
                                    .font(.system(size: 11, design: .monospaced))
                                Spacer()
                                Text("\(result.status.map(String.init) ?? "—") · \(result.reason)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(
                                        result.succeeded
                                            ? Theme.status(.done)
                                            : Theme.status(.blocked)
                                    )
                            }
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary)
                }

                SettingsSection(title: "Doctor") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(doctorFindings) { finding in
                            HStack(alignment: .top, spacing: 9) {
                                Circle()
                                    .fill(doctorColor(finding.severity))
                                    .frame(width: 8, height: 8)
                                    .padding(.top, 4)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(finding.title)
                                        .font(.system(size: 12, weight: .semibold))
                                    Text(finding.detail)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.textSecondary)
                                    Text("Fix: \(finding.fix)")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(Theme.textTertiary)
                                }
                            }
                        }
                    }
                    .foregroundStyle(Theme.textPrimary)
                }
            }
        }
        .settingsTabBackground()
    }

    private func remainingTime(until expiry: Date, now: Date) -> String {
        let seconds = max(0, Int(ceil(expiry.timeIntervalSince(now))))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func pushField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .foregroundStyle(Theme.textTertiary)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: .infinity)
    }

    private func doctorColor(_ severity: DoctorSeverity) -> Color {
        switch severity {
        case .green: .green
        case .amber: .orange
        case .red: .red
        }
    }

    private func companionValue(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .foregroundStyle(Theme.textTertiary)
            Text(value)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func pairingOption(title: String, address: String, url: URL?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            companionValue(label: "Address", value: address)
            if let url,
               let image = CompanionQRCode.image(for: url.absoluteString) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 150, height: 150)
                    .accessibilityLabel("\(title) companion pairing QR code")
                Text("Scan with rai for iPhone")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum CompanionQRCode {
    static func image(for value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: 180, height: 180))
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

                        Toggle("Copy on select", isOn: $settings.copyOnSelect)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        Text(
                            settings.copyOnSelect
                                ? "Finishing a drag-selection copies it and clears the highlight (herdr-style)."
                                : "Selections stay highlighted; copy with ⌘C (Ghostty-style)."
                        )
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
                        Toggle(
                            "Hold phone pushes while you're at this Mac",
                            isOn: $settings.holdPushesWhileAtMac
                        )
                        Text(
                            "The phone buzzes only if a pane still needs you "
                                + "after ~2 minutes without keyboard or mouse input. "
                                + "Mac notifications are unaffected."
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
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

    @State private var serverOutput = "Loading server status…"
    @State private var manifestOutput = "Loading agent detection manifests…"
    @State private var channelSelection = "stable"
    @State private var channelStatus = "Loading update channel…"
    @State private var news: [HerdrNewsItem] = []
    @State private var isRunningAction = false
    @State private var isStopConfirmationPresented = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsSection(title: "Current Server Status") {
                    ScrollView {
                        Text(serverOutput)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .frame(maxWidth: .infinity, minHeight: 90)
                }

                HStack(spacing: 10) {
                    Button("Refresh") {
                        Task { await refreshAll() }
                    }
                    Button("Reload Config") {
                        Task { await reloadConfig() }
                    }
                    Button("Live Handoff") {
                        Task { await liveHandoff() }
                    }
                    .disabled(model.remoteTarget != nil)
                    Button("Update herdr") {
                        Task { await updateHerdr() }
                    }
                    .disabled(model.remoteTarget != nil)
                    Spacer()
                    Button("Stop Server", role: .destructive) {
                        isStopConfirmationPresented = true
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isRunningAction)

                SettingsSection(title: "Update Channel") {
                    HStack(spacing: 12) {
                        Picker("Channel", selection: $channelSelection) {
                            Text("Stable").tag("stable")
                            Text("Preview").tag("preview")
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)

                        Button("Apply") {
                            Task { await setChannel() }
                        }
                        .buttonStyle(.bordered)

                        Text(channelStatus)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(2)
                    }
                    .disabled(isRunningAction || model.remoteTarget != nil)
                }

                ProjectRootsSection(model: model)

                SettingsSection(title: "Agent Detection Manifests") {
                    VStack(alignment: .leading, spacing: 12) {
                        ScrollView {
                            Text(manifestOutput)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                                .textSelection(.enabled)
                                .frame(
                                    maxWidth: .infinity,
                                    alignment: .topLeading
                                )
                        }
                        .frame(maxWidth: .infinity, minHeight: 110)

                        HStack(spacing: 8) {
                            Button("Refresh") {
                                Task { await refreshManifests() }
                            }
                            Button("Check for Updates") {
                                Task { await updateManifests() }
                            }
                            .disabled(model.remoteTarget != nil)
                            Button("Reload Cached") {
                                Task { await reloadManifests() }
                            }
                            Spacer()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isRunningAction)
                    }
                }

                SettingsSection(title: "Release Notes and Announcements") {
                    if news.isEmpty {
                        Text("Herdr has no stored release notes or announcements.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(news) { item in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title)
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .foregroundStyle(Theme.textPrimary)
                                    Text(item.subtitle)
                                        .font(.system(size: 10))
                                        .foregroundStyle(Theme.textTertiary)
                                    Text(item.body)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.textSecondary)
                                        .textSelection(.enabled)
                                        .fixedSize(
                                            horizontal: false,
                                            vertical: true
                                        )
                                }
                                if item.id != news.last?.id {
                                    Divider().overlay(Theme.hairlineStrong)
                                }
                            }
                        }
                    }
                }
            }
        }
        .settingsTabBackground()
        .task {
            await refreshAll()
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

    private func refreshAll() async {
        isRunningAction = true
        serverOutput = await model.serverStatus()
        manifestOutput = await model.agentManifestStatus()
        let channel = await model.herdrChannel()
        if channel == "stable" || channel == "preview" {
            channelSelection = channel
            channelStatus = "Current channel: \(channel)."
        } else {
            channelStatus = channel
        }
        news = model.herdrNews()
        isRunningAction = false
    }

    private func reloadConfig() async {
        isRunningAction = true
        if await model.reloadConfig() {
            serverOutput = await model.serverStatus()
        } else {
            serverOutput = "Unable to reload the Herdr server configuration."
        }
        isRunningAction = false
    }

    private func liveHandoff() async {
        isRunningAction = true
        serverOutput = await model.liveHandoff()
        if !serverOutput.localizedCaseInsensitiveContains("failed") {
            serverOutput += "\n\n" + (await model.serverStatus())
        }
        isRunningAction = false
    }

    private func updateHerdr() async {
        isRunningAction = true
        serverOutput = await model.updateHerdr()
        news = model.herdrNews()
        isRunningAction = false
    }

    private func setChannel() async {
        isRunningAction = true
        let result = await model.setHerdrChannel(channelSelection)
        channelStatus = result.output
        if result.succeeded {
            let channel = await model.herdrChannel()
            if channel == "stable" || channel == "preview" {
                channelSelection = channel
                channelStatus = "Current channel: \(channel)."
            }
        }
        isRunningAction = false
    }

    private func refreshManifests() async {
        isRunningAction = true
        manifestOutput = await model.agentManifestStatus()
        isRunningAction = false
    }

    private func updateManifests() async {
        isRunningAction = true
        manifestOutput = await model.updateAgentManifests()
        isRunningAction = false
    }

    private func reloadManifests() async {
        isRunningAction = true
        manifestOutput = await model.reloadAgentManifests()
        isRunningAction = false
    }

    private func stopServer() async {
        isRunningAction = true
        if await model.stopServer() {
            serverOutput = "Herdr server stopped."
        } else {
            serverOutput = "Unable to stop the Herdr server."
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
        let build: [Command]
        let startup: [Command]
        let actions: [Action]
        let panes: [Pane]
        let linkHandlers: [LinkHandler]
        let source: Source?

        var id: String { pluginID }
        var isManagedInstall: Bool { source?.kind == "github" }

        var boundCommands: [BoundCommand] {
            var bindings = build.enumerated().map {
                BoundCommand(
                    id: "build-\($0.offset)",
                    label: "Build",
                    command: $0.element.command.joined(separator: " ")
                )
            }
            bindings += startup.enumerated().map {
                BoundCommand(
                    id: "startup-\($0.offset)",
                    label: "Startup",
                    command: $0.element.command.joined(separator: " ")
                )
            }
            bindings += actions.enumerated().map {
                BoundCommand(
                    id: "action-\($0.offset)-\($0.element.id)",
                    label: "Action · \($0.element.title)",
                    command: $0.element.command.joined(separator: " ")
                )
            }
            bindings += events.enumerated().map {
                BoundCommand(
                    id: "event-\($0.offset)-\($0.element.on)",
                    label: "Event · \($0.element.on)",
                    command: $0.element.command.joined(separator: " ")
                )
            }
            bindings += panes.enumerated().map {
                BoundCommand(
                    id: "pane-\($0.offset)-\($0.element.id)",
                    label: "Pane · \($0.element.title) · \($0.element.placement)",
                    command: $0.element.command.joined(separator: " ")
                )
            }
            bindings += linkHandlers.enumerated().map {
                BoundCommand(
                    id: "link-\($0.offset)-\($0.element.id)",
                    label: "Link · \($0.element.title)",
                    command: "\($0.element.pattern) → \($0.element.action)"
                )
            }
            return bindings
        }

        private enum CodingKeys: String, CodingKey {
            case pluginID = "plugin_id"
            case name
            case description
            case enabled
            case events
            case build
            case startup
            case actions
            case panes
            case linkHandlers = "link_handlers"
            case source
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            pluginID = try container.decode(String.self, forKey: .pluginID)
            name = try container.decode(String.self, forKey: .name)
            description = try container.decodeIfPresent(
                String.self,
                forKey: .description
            ) ?? "No description."
            enabled = try container.decode(Bool.self, forKey: .enabled)
            events = try container.decodeIfPresent(
                [Event].self,
                forKey: .events
            ) ?? []
            build = try container.decodeIfPresent(
                [Command].self,
                forKey: .build
            ) ?? []
            startup = try container.decodeIfPresent(
                [Command].self,
                forKey: .startup
            ) ?? []
            actions = try container.decodeIfPresent(
                [Action].self,
                forKey: .actions
            ) ?? []
            panes = try container.decodeIfPresent(
                [Pane].self,
                forKey: .panes
            ) ?? []
            linkHandlers = try container.decodeIfPresent(
                [LinkHandler].self,
                forKey: .linkHandlers
            ) ?? []
            source = try container.decodeIfPresent(Source.self, forKey: .source)
        }
    }

    struct Event: Decodable {
        let on: String
        let command: [String]
    }

    struct Command: Decodable {
        let command: [String]
    }

    struct Action: Decodable {
        let id: String
        let title: String
        let command: [String]
    }

    struct Pane: Decodable {
        let id: String
        let title: String
        let placement: String
        let command: [String]
    }

    struct LinkHandler: Decodable {
        let id: String
        let title: String
        let pattern: String
        let action: String
    }

    struct Source: Decodable {
        let kind: String
    }

    struct BoundCommand: Identifiable {
        let id: String
        let label: String
        let command: String
    }
}

private struct PluginsSettingsView: View {
    @ObservedObject var model: RaiModel

    @State private var plugins: [PluginListResponse.Plugin] = []
    @State private var isLoading = false
    @State private var isRunningAction = false
    @State private var activePluginIDs: Set<String> = []
    @State private var status: String?
    @State private var installSource = ""
    @State private var installReference = ""
    @State private var installPreview: HerdrPluginInstallPreview?
    @State private var pluginPendingRemoval: PluginListResponse.Plugin?
    @State private var pluginForLogs: PluginListResponse.Plugin?
    @State private var pluginForCommands: PluginListResponse.Plugin?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSection(title: "Add Plugin") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        TextField(
                            "owner/repo[/subdir...]",
                            text: $installSource
                        )
                        TextField("Git ref (optional)", text: $installReference)
                            .frame(width: 150)
                    }
                    .textFieldStyle(.roundedBorder)

                    HStack(spacing: 8) {
                        Button("Install from GitHub") {
                            Task { await installPlugin() }
                        }
                        .disabled(
                            installSource.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty
                        )
                        Button("Link Local Directory", action: choosePluginDirectory)
                        Spacer()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isRunningAction)

                    Text(
                        "Install accepts Herdr’s owner/repository shorthand. "
                            + "Link keeps the plugin in its local directory."
                    )
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)

                    if model.remoteTarget != nil {
                        Text("Add and uninstall actions require a local Herdr server.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .disabled(model.remoteTarget != nil)
            }

            HStack {
                Text("Manage plugins in this Herdr installation.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button("Refresh") {
                    Task { await refreshPlugins() }
                }
                .buttonStyle(.bordered)
                .disabled(
                    isLoading
                        || isRunningAction
                        || !activePluginIDs.isEmpty
                )
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
                                        isRunningAction: isRunningAction
                                            || activePluginIDs.contains(plugin.id),
                                        canRemove: !plugin.isManagedInstall
                                            || model.remoteTarget == nil,
                                        onEnabledChange: { enabled in
                                            setEnabled(enabled, for: plugin)
                                        },
                                        onLogs: {
                                            pluginForLogs = plugin
                                        },
                                        onCommands: {
                                            pluginForCommands = plugin
                                        },
                                        onRemove: {
                                            pluginPendingRemoval = plugin
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
        .onDisappear {
            guard isRunningAction else { return }
            Task { await model.cancelPluginInstall() }
        }
        .alert(
            "\(pluginPendingRemoval?.isManagedInstall == true ? "Uninstall" : "Unlink") "
                + "\(pluginPendingRemoval?.name ?? "Plugin")?",
            isPresented: Binding(
                get: { pluginPendingRemoval != nil },
                set: { if !$0 { pluginPendingRemoval = nil } }
            ),
            presenting: pluginPendingRemoval
        ) { plugin in
            Button("Cancel", role: .cancel) {}
            Button(
                plugin.isManagedInstall ? "Uninstall" : "Unlink",
                role: .destructive
            ) {
                Task { await remove(plugin) }
            }
        } message: { plugin in
            Text(
                plugin.isManagedInstall
                    ? "This removes \(plugin.pluginID) and its managed checkout."
                    : "This unlinks \(plugin.pluginID) from Herdr."
            )
        }
        .sheet(item: $pluginForLogs) { plugin in
            PluginLogsSheet(model: model, plugin: plugin)
        }
        .sheet(item: $pluginForCommands) { plugin in
            PluginCommandsSheet(plugin: plugin)
        }
        .sheet(item: $installPreview) { preview in
            PluginInstallPreviewSheet(
                preview: preview,
                onCancel: cancelPluginInstall,
                onInstall: confirmPluginInstall
            )
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

    private func installPlugin() async {
        let source = installSource.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let reference = installReference.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !source.isEmpty else { return }
        isRunningAction = true
        status = "Reading \(source)…"
        let preview = await model.preparePluginInstall(
            source: source,
            reference: reference
        )
        if preview.canConfirm {
            installPreview = preview
        } else {
            status = preview.output
            isRunningAction = false
        }
    }

    private func confirmPluginInstall() {
        installPreview = nil
        status = "Installing plugin…"
        Task {
            let output = await model.confirmPluginInstall()
            await refreshPlugins()
            status = output
            isRunningAction = false
        }
    }

    private func cancelPluginInstall() {
        installPreview = nil
        Task {
            await model.cancelPluginInstall()
            status = "Plugin install cancelled."
            isRunningAction = false
        }
    }

    private func choosePluginDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Link Herdr Plugin"
        panel.message = "Choose a directory that contains herdr-plugin.toml."
        panel.prompt = "Link"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await linkPlugin(at: url) }
    }

    private func linkPlugin(at url: URL) async {
        isRunningAction = true
        status = "Linking \(url.lastPathComponent)…"
        let output = await model.pluginLink(path: url.path)
        await refreshPlugins()
        status = output
        isRunningAction = false
    }

    private func remove(_ plugin: PluginListResponse.Plugin) async {
        pluginPendingRemoval = nil
        activePluginIDs.insert(plugin.id)
        if plugin.isManagedInstall {
            let output = await model.pluginUninstall(plugin.pluginID)
            await refreshPlugins()
            status = output
        } else if await model.pluginUnlink(plugin.pluginID) {
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
    let canRemove: Bool
    let onEnabledChange: (Bool) -> Void
    let onLogs: () -> Void
    let onCommands: () -> Void
    let onRemove: () -> Void

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
                Button(
                    "Commands (\(plugin.boundCommands.count))",
                    action: onCommands
                )
                Button(
                    plugin.isManagedInstall ? "Uninstall" : "Unlink",
                    role: .destructive,
                    action: onRemove
                )
                .disabled(!canRemove)
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

private struct PluginCommandsSheet: View {
    let plugin: PluginListResponse.Plugin

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Plugin Commands")
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

            if plugin.boundCommands.isEmpty {
                Text("This plugin does not bind commands.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(plugin.boundCommands) { binding in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(binding.label)
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(Theme.textSecondary)
                                Text(binding.command)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(Theme.textPrimary)
                                    .textSelection(.enabled)
                                    .fixedSize(
                                        horizontal: false,
                                        vertical: true
                                    )
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 600, height: 420)
        .background(Theme.raised)
    }
}

private struct PluginInstallPreviewSheet: View {
    let preview: HerdrPluginInstallPreview
    let onCancel: () -> Void
    let onInstall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Review Plugin Install")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Herdr will run the listed build commands after confirmation.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
            }

            ScrollView {
                Text(preview.output)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Install", action: onInstall)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 600, height: 440)
        .background(Theme.raised)
        .interactiveDismissDisabled()
    }
}

private struct IntegrationsSettingsView: View {
    @ObservedObject var model: RaiModel
    @ObservedObject private var settings = SettingsStore.shared

    @State private var activeIntegration: String?
    @State private var hooksPreview: ClaudeHooksPreview?
    @State private var claudeSettingsPath = ClaudeHooksInstaller.defaultSettingsURL.path
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

            SettingsSection(title: "Claude Code Hooks") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(
                        "Rai copies its hook to Application Support, then merges owner-only user settings."
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)

                    Toggle("Answer from the phone", isOn: $settings.answerFromPhone)

                    HStack {
                        Text("Hold a permission prompt")
                        Spacer()
                        Stepper(
                            "\(settings.answerFromPhoneHoldSeconds) seconds",
                            value: $settings.answerFromPhoneHoldSeconds,
                            in: ClaudeHookSettings.minimumDecisionHoldSeconds...ClaudeHookSettings.maximumDecisionHoldSeconds
                        )
                    }
                    .disabled(!settings.answerFromPhone)

                    Text(
                        "Reinstall hooks after changing the hold. The preview shows a \(ClaudeHookSettings.claudeTimeout(forHoldSeconds: settings.answerFromPhoneHoldSeconds))-second Claude timeout."
                    )
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)

                    HStack(spacing: 8) {
                        TextField("Claude settings.json path", text: $claudeSettingsPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Choose…") { chooseClaudeSettingsDirectory() }
                            .buttonStyle(.bordered)
                    }

                    HStack(spacing: 8) {
                        Button("Install Claude Code hooks") {
                            prepareHooksPreview(.install)
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Remove", role: .destructive) {
                            prepareHooksPreview(.remove)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

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
        .sheet(item: $hooksPreview) { preview in
            ClaudeHooksPreviewSheet(
                preview: preview,
                onCancel: { hooksPreview = nil },
                onConfirm: { applyHooksPreview(preview) }
            )
        }
    }

    private func prepareHooksPreview(_ action: ClaudeHooksAction) {
        do {
            let path = NSString(string: claudeSettingsPath).expandingTildeInPath
            hooksPreview = try ClaudeHooksInstaller.makePreview(
                action: action,
                settingsURL: URL(fileURLWithPath: path),
                decisionHoldSeconds: settings.answerFromPhoneHoldSeconds
            )
            status = "Review the settings preview before you confirm."
        } catch {
            status = error.localizedDescription
        }
    }

    private func chooseClaudeSettingsDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose Claude Code settings directory"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        let current = URL(fileURLWithPath: NSString(
            string: claudeSettingsPath
        ).expandingTildeInPath)
        panel.directoryURL = current.deletingLastPathComponent()
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        claudeSettingsPath = directory.appendingPathComponent("settings.json").path
    }

    private func applyHooksPreview(_ preview: ClaudeHooksPreview) {
        do {
            try ClaudeHooksInstaller.apply(preview)
            status = preview.action == .install
                ? "Claude Code hooks installed. Rai backs up an existing settings file."
                : "Claude Code hook entries removed. Rai keeps the shared hook script."
            hooksPreview = nil
        } catch {
            status = error.localizedDescription
        }
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

private struct ClaudeHooksPreviewSheet: View {
    let preview: ClaudeHooksPreview
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(preview.action.rawValue) Claude Code Hooks")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Proposed ~/.claude/settings.json")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            ScrollView([.horizontal, .vertical]) {
                Text(preview.text)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(Theme.base)
            .clipShape(RoundedRectangle(cornerRadius: 7))

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button(preview.action.rawValue, action: onConfirm)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 620, height: 480)
        .background(Theme.raised)
        .interactiveDismissDisabled()
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

/// Where the command palette looks for repos to open as spaces.
///
/// The scan runs on the herd's own host, so these paths are read on the remote
/// machine while rai is attached to a remote herd. That is why the folder
/// picker disappears there: it would browse this Mac, not the herd's host.
private struct ProjectRootsSection: View {
    @ObservedObject var model: RaiModel

    @State private var draft = ""

    private var isRemote: Bool { model.remoteTarget != nil }

    var body: some View {
        SettingsSection(title: "Project Roots") {
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    isRemote
                        ? "Scanned on \(model.remoteTarget ?? "the remote host") "
                            + "for git checkouts. Found \(model.discoveredRepos.count)."
                        : "Scanned for git checkouts offered in the command palette. "
                            + "Found \(model.discoveredRepos.count)."
                )
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)

                if model.repoRoots.isEmpty {
                    Text("No roots. The palette lists open spaces only.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.repoRoots, id: \.self) { root in
                            HStack(spacing: 8) {
                                Text(root)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                Spacer()
                                Button {
                                    remove(root)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove this root")
                            }
                        }
                    }
                }

                HStack(spacing: 8) {
                    TextField("~/projects", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5, design: .monospaced))
                        .onSubmit(addDraft)
                    Button("Add", action: addDraft)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    if !isRemote {
                        Button("Choose…", action: chooseFolder)
                    }
                }
                .buttonStyle(.bordered)

                HStack(spacing: 10) {
                    Stepper(
                        "Depth: \(model.repoDepth)",
                        value: Binding(
                            get: { model.repoDepth },
                            set: { model.repoDepth = $0 }
                        ),
                        in: 1...RepoDiscoveryPlanner.maxDepth
                    )
                    .font(.system(size: 11.5))
                    Text("levels below each root")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                    Button("Rescan") { model.refreshRepoIndex() }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private func addDraft() {
        let value = draft.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !model.repoRoots.contains(value) else {
            draft = ""
            return
        }
        model.repoRoots = model.repoRoots + [value]
        draft = ""
    }

    private func remove(_ root: String) {
        model.repoRoots = model.repoRoots.filter { $0 != root }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Root"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft = NSString(string: url.path).abbreviatingWithTildeInPath
        addDraft()
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

/// Codex Micro macropad integration.
///
/// Device status is live: "enabled" is a user preference, "connected" means a
/// device is actually attached. Keeping them visibly separate matters because
/// the pad disconnects on its own, and because another process holding it
/// (Karabiner seizes keyboards, and every node on this pad carries a Keyboard
/// collection) looks identical to "not plugged in" without an explicit reason.
private struct CodexMicroSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var status = MicroStatusCenter.shared
    @ObservedObject private var bindings = MicroStatusCenter.shared.bindings
    @State private var learningFrom: MicroControl?
    @State private var presentedBindingEditor: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
            Text("A Work Louder Codex Micro drives your agents: the six keys hold your agents in sidebar order, their colour tracks agent state, the dial scrolls through every agent, and the joystick moves focus.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            SettingsSection(title: "Integration") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Enable Codex Micro", isOn: $status.isEnabled)
                    Text("Takes effect immediately. Connect over USB or pair over Bluetooth; the pad is picked up whenever it appears and re-attached after it drops.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsSection(title: "Device") {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Status") {
                        Text(status.isConnected ? "Connected" : (status.isEnabled ? "Waiting for device" : "Disabled"))
                            .foregroundStyle(status.isConnected ? Theme.status(.done) : Theme.textSecondary)
                    }
                    if let transport = status.transportName {
                        LabeledContent("Transport") { Text(transport) }
                    }
                    if let node = status.nodeID {
                        LabeledContent("Node") {
                            Text(String(format: "0x%llX", node))
                                .font(.system(size: 11, design: .monospaced))
                        }
                    }
                    if status.isConnected {
                        LabeledContent("Lighting writes accepted") {
                            Text("\(status.acknowledgedWrites)")
                                .font(.system(size: 11, design: .monospaced))
                        }
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textPrimary)
            }

            SettingsSection(title: "Buttons") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        if let control = status.lastPressedControl {
                            Text("Last pressed: \(control.displayName)")
                                .foregroundStyle(Theme.textSecondary)
                        } else {
                            Text("Press a control to identify it.")
                                .foregroundStyle(Theme.textTertiary)
                        }
                        Spacer()
                        Button("Reset to defaults") {
                            learningFrom = nil
                            bindings.reset()
                        }
                    }
                    .font(.system(size: 10.5))

                    visualPad
                        .frame(maxWidth: .infinity)
                }
            }

            if let error = status.lastError {
                SettingsSection(title: "Last Error") {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.status(.blocked))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Theme.base)
        .onChange(of: status.pressSequence) { _, _ in
            guard let source = learningFrom,
                  let pressed = status.lastPressedControl else {
                return
            }
            bindings[pressed] = bindings[source]
            learningFrom = nil
        }
    }

    private var visualPad: some View {
        // ACT key positions are approximate until confirmed on hardware via learn mode.
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                // Mirrors the physical pad: dial on the left, joystick on the right.
                aggregateControl(
                    title: "Dial",
                    controls: dialControls,
                    kind: .dial
                )
                keyCell(.agentKey(0))
                keyCell(.agentKey(1))
                aggregateControl(
                    title: "Joystick",
                    controls: joystickControls,
                    kind: .joystick
                )
            }
            GridRow {
                keyCell(.agentKey(2))
                keyCell(.agentKey(3))
                keyCell(.agentKey(4))
                keyCell(.agentKey(5))
            }
            GridRow {
                keyCell(.commandKey("ACT06"))
                keyCell(.commandKey("ACT07"))
                keyCell(.commandKey("ACT08"))
                keyCell(.commandKey("ACT09"))
            }
            GridRow {
                // The device's touch button sits at the bottom-left.
                spareCell
                keyCell(.commandKey("ACT10"))
                keyCell(.commandKey("ACT11"))
                keyCell(.commandKey("ACT12"))
            }
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(padBodyColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .inset(by: 1)
                .stroke(padOutlineColor, lineWidth: 1)
        )
        .onAppear {
            status.isBindingEditorActive = true
        }
        .onDisappear {
            status.isBindingEditorActive = false
        }
    }

    @ViewBuilder
    private func keyCell(_ control: MicroControl) -> some View {
        let action = bindings[control]
        Button {
            presentedBindingEditor = control.id
        } label: {
            VStack(spacing: 4) {
                Group {
                    if action == .none {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 26, height: 26)
                            .overlay(Circle().stroke(Theme.textTertiary, lineWidth: 1))
                    } else {
                        actionLabel(action)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Text(control.displayName)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .padding(7)
            .frame(width: 76, height: 76)
            .background(keyColor)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(cellBorder(highlighted: status.lastPressedControl == control))
        }
        .buttonStyle(.plain)
        .popover(isPresented: bindingEditorPresented(control.id)) {
            bindingPopover(control)
        }
        .help("Configure \(control.displayName)")
    }

    private enum RoundControlKind: Equatable {
        case joystick
        case dial
    }

    private func aggregateControl(
        title: String,
        controls: [MicroControl],
        kind: RoundControlKind
    ) -> some View {
        let highlighted = status.lastPressedControl.map(controls.contains) ?? false
        return Button {
            presentedBindingEditor = "group.\(title)"
        } label: {
            VStack(spacing: 3) {
                Image(systemName: kind == .joystick ? "move.3d" : "dial.medium")
                    .font(.system(size: 19, weight: .medium))
                Text(title)
                    .font(.system(size: 9.5, weight: .medium))
            }
            .foregroundStyle(kind == .dial ? Color.white.opacity(0.88) : Theme.textSecondary)
            .frame(width: 76, height: 76)
            .background {
                Circle()
                    .fill(kind == .dial ? dialColor : keyColor)
                if kind == .joystick {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.28), .clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            }
            .overlay(Circle().stroke(
                highlighted ? Theme.accent : Theme.hairlineStrong,
                lineWidth: highlighted ? 2 : 1
            ))
        }
        .buttonStyle(.plain)
        .popover(isPresented: bindingEditorPresented("group.\(title)")) {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                ForEach(controls, id: \.id) { control in
                    compactBindingRow(control)
                }
            }
            .padding(16)
            .frame(width: 430)
        }
        .help("Configure \(title.lowercased()) controls")
    }

    private var spareCell: some View {
        Circle()
            .fill(keyColor.opacity(0.55))
            .overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
            .frame(width: 76, height: 76)
            .accessibilityHidden(true)
    }

    private func bindingPopover(_ control: MicroControl) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(control.displayName)
                .font(.system(size: 13, weight: .semibold))
            actionPicker(control)
            customValueField(control)
            learnButton(control)
        }
        .padding(16)
        .frame(width: 330)
    }

    private func compactBindingRow(_ control: MicroControl) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(control.displayName)
                    .font(.system(size: 11.5))
                    .frame(width: 120, alignment: .leading)
                actionPicker(control)
                learnButton(control)
            }
            customValueField(control)
                .padding(.leading, 130)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    status.lastPressedControl == control
                        ? Theme.accent.opacity(0.12)
                        : Color.clear
                )
        )
    }

    private func actionPicker(_ control: MicroControl) -> some View {
        Picker("", selection: actionSelection(control)) {
            ForEach(actionGroups, id: \.self) { group in
                Section(group) {
                    ForEach(
                        MicroAction.catalog.filter { $0.group == group },
                        id: \.catalogID
                    ) { candidate in
                        Text(candidate.displayName)
                            .tag(candidate.catalogID)
                    }
                }
            }
        }
        .labelsHidden()
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func customValueField(_ control: MicroControl) -> some View {
        switch bindings[control] {
        case .customKeys(let value):
            TextField(
                "herdr key name (for example C-c or Escape)",
                text: customValue(control, value: value, keys: true)
            )
            .textFieldStyle(.roundedBorder)
        case .customText(let value):
            TextField(
                "Text to send, followed by Return",
                text: customValue(control, value: value, keys: false)
            )
            .textFieldStyle(.roundedBorder)
        default:
            EmptyView()
        }
    }

    private func learnButton(_ control: MicroControl) -> some View {
        Button(learningFrom == control ? "Listening…" : "Set by pressing") {
            learningFrom = learningFrom == control ? nil : control
        }
        .font(.system(size: 10.5))
        .help("Copy this action to the next physical control you press")
    }

    @ViewBuilder
    private func actionLabel(_ action: MicroAction) -> some View {
        switch action {
        case .customKeys(let value), .customText(let value):
            Text(value.isEmpty ? action.displayName : value)
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .lineLimit(2)
                .multilineTextAlignment(.center)
        default:
            Text(action.displayName)
                .font(.system(size: 9.5, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
    }

    private func cellBorder(highlighted: Bool) -> some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(
                highlighted ? Theme.accent : Theme.hairlineStrong,
                lineWidth: highlighted ? 2 : 1
            )
    }

    private var padBodyColor: Color {
        colorScheme == .dark ? Theme.raised.opacity(0.72) : Theme.base
    }

    private var padOutlineColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.75)
    }

    private var keyColor: Color {
        colorScheme == .dark ? Theme.base.opacity(0.92) : Theme.raised
    }

    private var dialColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.72) : Color.black.opacity(0.70)
    }

    private let joystickControls = MicroJoystickDirection.allCases.map(MicroControl.joystick)
    private let dialControls: [MicroControl] = [
        .dialClockwise, .dialCounterClockwise, .dialPress,
    ]

    private let actionGroups = [
        "To focused agent", "Navigate", "Tabs/spaces", "App",
    ]

    private func bindingEditorPresented(_ id: String) -> Binding<Bool> {
        Binding(
            get: { presentedBindingEditor == id },
            set: { isPresented in
                if !isPresented, presentedBindingEditor == id {
                    presentedBindingEditor = nil
                }
            }
        )
    }

    private func actionSelection(_ control: MicroControl) -> Binding<String> {
        Binding(
            get: { bindings[control].catalogID },
            set: { id in
                guard let action = MicroAction.catalog.first(where: {
                    $0.catalogID == id
                }) else { return }
                bindings[control] = action
            }
        )
    }

    private func customValue(
        _ control: MicroControl,
        value: String,
        keys: Bool
    ) -> Binding<String> {
        Binding(
            get: {
                switch bindings[control] {
                case .customKeys(let current), .customText(let current):
                    current
                default:
                    value
                }
            },
            set: {
                bindings[control] = keys ? .customKeys($0) : .customText($0)
            }
        )
    }
}
