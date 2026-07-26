import AppKit
import RaiCore
import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }
    var label: String { rawValue.capitalized }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum ThemeVariant: String, CaseIterable, Identifiable {
    case light
    case dark

    var id: Self { self }
    var label: String { rawValue.capitalized }
}

enum ThemeColorRole: String, CaseIterable, Identifiable {
    case accent
    case statusWorking
    case statusBlocked
    case statusDone
    case statusIdle
    case statusUnknown
    case base
    case sidebar
    case raised
    case bar
    case terminalBG
    case textPrimary
    case textSecondary
    case textTertiary
    case hairline

    var id: Self { self }

    var label: String {
        switch self {
        case .accent: "Accent"
        case .statusWorking: "Working"
        case .statusBlocked: "Blocked"
        case .statusDone: "Done"
        case .statusIdle: "Idle"
        case .statusUnknown: "Unknown"
        case .base: "Base"
        case .sidebar: "Sidebar"
        case .raised: "Raised"
        case .bar: "Bar"
        case .terminalBG: "Terminal"
        case .textPrimary: "Primary"
        case .textSecondary: "Secondary"
        case .textTertiary: "Tertiary"
        case .hairline: "Hairline"
        }
    }
}

struct ThemePalette {
    let colors: [ThemeColorRole: RGBAColor]

    subscript(_ role: ThemeColorRole) -> RGBAColor {
        colors[role]!
    }

    static let dark = ThemePalette(colors: [
        .base: .hex(0x1A1A1A),
        .sidebar: .hex(0x1F1F1F),
        .raised: .hex(0x2C2C2E),
        .bar: .hex(0x1C1C1C),
        .terminalBG: .hex(0x212121),
        .textPrimary: .hex(0xF8F8F2),
        .textSecondary: .hex(0x9EA0AD),
        .textTertiary: .hex(0x6272A4),
        .accent: .hex(0xC792EA),
        .statusWorking: .hex(0x82AAFF),
        .statusBlocked: .hex(0xFF5555),
        .statusDone: .hex(0x50FA7B),
        .statusIdle: .hex(0x6272A4),
        .statusUnknown: .hex(0x44475A),
        .hairline: .white(opacity: 0.07),
    ])

    static let light = ThemePalette(colors: [
        .base: .hex(0xF5F5F7),
        .sidebar: .hex(0xECECF0),
        .raised: .hex(0xFFFFFF),
        .bar: .hex(0xF0F0F3),
        .terminalBG: .hex(0xFAFAFC),
        .textPrimary: .hex(0x202124),
        .textSecondary: .hex(0x5F6368),
        .textTertiary: .hex(0x7B8190),
        .accent: .hex(0x7651B2),
        .statusWorking: .hex(0x2563B9),
        .statusBlocked: .hex(0xC9363E),
        .statusDone: .hex(0x238636),
        .statusIdle: .hex(0x687386),
        .statusUnknown: .hex(0xA0A5AE),
        .hairline: .black(opacity: 0.10),
    ])
}

struct RGBAColor: Codable, Equatable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    static func hex(_ hex: UInt32, alpha: Double = 1) -> Self {
        Self(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    static func white(opacity: Double) -> Self {
        Self(red: 1, green: 1, blue: 1, alpha: opacity)
    }

    static func black(opacity: Double) -> Self {
        Self(red: 0, green: 0, blue: 0, alpha: opacity)
    }

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    init?(color: Color) {
        guard let converted = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        red = converted.redComponent
        green = converted.greenComponent
        blue = converted.blueComponent
        alpha = converted.alphaComponent
    }
}

/// Configures the window for the solid, opaque theme surface.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.isOpaque = true
        window.backgroundColor = Theme.nsColor(.base)
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
    }
}

// Static computed accessors keep view call sites terse while SettingsStore
// supplies the live, persisted palette.
@MainActor
enum Theme {
    static let radiusRow: CGFloat = 6
    static let radiusPane: CGFloat = 7
    static let radiusCard: CGFloat = 8
    static let headerHeight: CGFloat = 56
    static let contentTopInset: CGFloat = 30

    static var activeVariant: ThemeVariant {
        SettingsStore.shared.activeThemeVariant
    }

    static func rgba(_ role: ThemeColorRole) -> RGBAColor {
        SettingsStore.shared.resolvedColor(role, for: activeVariant)
    }

    static func nsColor(_ role: ThemeColorRole) -> NSColor {
        rgba(role).nsColor
    }

    static var base: Color { rgba(.base).color }
    static var sidebar: Color { rgba(.sidebar).color }
    static var raised: Color { rgba(.raised).color }
    static var bar: Color { rgba(.bar).color }
    static var terminalBG: Color { rgba(.terminalBG).color }
    static var textPrimary: Color { rgba(.textPrimary).color }
    static var textSecondary: Color { rgba(.textSecondary).color }
    static var textTertiary: Color { rgba(.textTertiary).color }
    static var accent: Color { rgba(.accent).color }
    static var hairline: Color { rgba(.hairline).color }
    static var hairlineStrong: Color { rgba(.hairline).color.opacity(11.0 / 7.0) }
    static var topHighlight: Color {
        activeVariant == .dark ? Color.white.opacity(0.04) : Color.white.opacity(0.55)
    }
    static func interactionWash(opacity: Double) -> Color {
        (activeVariant == .dark ? Color.white : Color.black).opacity(opacity)
    }
    static var panelGradient: LinearGradient {
        LinearGradient(colors: [sidebar, base], startPoint: .top, endPoint: .bottom)
    }

    static func status(_ status: AgentStatus) -> Color {
        let role: ThemeColorRole = switch status {
        case .working: .statusWorking
        case .blocked: .statusBlocked
        case .done: .statusDone
        case .idle: .statusIdle
        case .unknown: .statusUnknown
        }
        return rgba(role).color
    }

    static func statusLabel(_ status: AgentStatus) -> String {
        switch status {
        case .working: "Working"
        case .blocked: "Needs you"
        case .done: "Done"
        case .idle: "Idle"
        case .unknown: "Unknown"
        }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self = RGBAColor.hex(hex, alpha: alpha).color
    }
}

struct StatusDot: View {
    let status: AgentStatus
    var size: CGFloat = 8

    @State private var pulse = false

    private var color: Color { Theme.status(status) }
    private var isHollow: Bool { status == .idle || status == .unknown }
    private var box: CGFloat { size + 8 }

    var body: some View {
        ZStack {
            if status == .working {
                Circle()
                    .stroke(color.opacity(0.6), lineWidth: 1.5)
                    .frame(width: size, height: size)
                    .scaleEffect(pulse ? 2.1 : 0.9)
                    .opacity(pulse ? 0 : 0.7)
            }
            if isHollow {
                Circle()
                    .strokeBorder(color, lineWidth: 1.4)
                    .frame(width: size - 1, height: size - 1)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: size, height: size)
                    .shadow(color: color.opacity(0.55), radius: status == .blocked ? 4 : 2)
            }
        }
        .frame(width: box, height: box)
        .onAppear {
            guard status == .working else { return }
            withAnimation(.easeOut(duration: 1.5).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
        .accessibilityLabel(Theme.statusLabel(status))
    }
}
