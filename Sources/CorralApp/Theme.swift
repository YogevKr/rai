import AppKit
import CorralCore
import SwiftUI

/// Native window vibrancy (NSVisualEffectView) — the translucent "glass" depth
/// Raycast/Finder use. Rendered dark via a tint overlay at the call site.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

// The corral design language: a single, deliberately-designed dark theme
// (a terminal product should own its palette rather than inherit the system's).
// One accent, a semantic status-color set, an 8pt spacing rhythm.
enum Theme {
    // Layered surfaces (deepest → raised). The content backdrop is the darkest
    // "stage" the panes float on; the sidebar is a distinct panel; the terminal
    // keeps the Ghostty Dracula+ bg. Depth (not flat grey) is what reads premium.
    static let base = Color(hex: 0x0E0F13)        // window / content backdrop (deepest)
    static let sidebar = Color(hex: 0x15161D)     // sidebar panel
    static let raised = Color(hex: 0x23252F)      // hover fills, chips
    static let bar = Color(hex: 0x121319)         // header bars
    static let terminalBG = Color(hex: 0x212121)  // Ghostty Dracula+ bg (matches SwiftTerm)

    // A subtle top-lit gradient + hairline highlight for panels — "light from above".
    static let panelGradient = LinearGradient(
        colors: [Color(hex: 0x191A22), Color(hex: 0x131319)],
        startPoint: .top, endPoint: .bottom
    )
    static let topHighlight = Color.white.opacity(0.05)

    // Hairlines.
    static let hairline = Color.white.opacity(0.05)
    static let hairlineStrong = Color.white.opacity(0.10)

    // Text hierarchy.
    static let textPrimary = Color(hex: 0xEDEEF3)
    static let textSecondary = Color(hex: 0x9A9FB2)
    static let textTertiary = Color(hex: 0x585D70)

    // Refined accent (Dracula+ blue, matches your Ghostty) — selection, focus, pulse.
    static let accent = Color(hex: 0x82AAFF)

    // Softened, less-neon status colors read more premium on a dark ground.
    static func status(_ s: AgentStatus) -> Color {
        switch s {
        case .working: Color(hex: 0x6FB6FF)   // soft blue
        case .blocked: Color(hex: 0xFF7A88)   // coral (needs you)
        case .done: Color(hex: 0x54D999)      // green
        case .idle: Color(hex: 0x676C82)      // muted
        case .unknown: Color(hex: 0x3C4054)
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
