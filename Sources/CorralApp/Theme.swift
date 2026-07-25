import CorralCore
import SwiftUI

// The corral design language: a single, deliberately-designed dark theme
// (a terminal product should own its palette rather than inherit the system's).
// One accent, a semantic status-color set, an 8pt spacing rhythm.
enum Theme {
    // Surfaces, deepest → most raised. Dracula-family greys so the whole app reads
    // as one theme with the Dracula+ terminal (bg #212121).
    static let base = Color(hex: 0x1B1C24)        // window / content backdrop
    static let sidebar = Color(hex: 0x21222C)     // elevated sidebar (Dracula ANSI black)
    static let raised = Color(hex: 0x343746)      // hover fills, chips (Dracula current-line-ish)
    static let bar = Color(hex: 0x1B1C24)         // header bars
    static let terminalBG = Color(hex: 0x212121)  // Ghostty Dracula+ bg (matches SwiftTerm)

    // Hairlines.
    static let hairline = Color.white.opacity(0.06)
    static let hairlineStrong = Color.white.opacity(0.12)

    // Text hierarchy (Dracula foreground / comment).
    static let textPrimary = Color(hex: 0xF8F8F2)
    static let textSecondary = Color(hex: 0xBBBDD0)
    static let textTertiary = Color(hex: 0x6272A4)

    // Dracula+ blue (your Ghostty palette[4]) — selection, focus, the live pulse.
    static let accent = Color(hex: 0x82AAFF)

    static func status(_ s: AgentStatus) -> Color {
        switch s {
        case .working: Color(hex: 0x8BE9FD)   // cyan
        case .blocked: Color(hex: 0xFF5555)   // red
        case .done: Color(hex: 0x50FA7B)      // green
        case .idle: Color(hex: 0x6272A4)      // comment
        case .unknown: Color(hex: 0x44475A)   // current line
        }
    }

    static func statusLabel(_ s: AgentStatus) -> String {
        switch s {
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
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

// A consistent status indicator: a hollow ring for idle/unknown (nothing
// happening), a solid dot for done/blocked, and a breathing halo for working.
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
