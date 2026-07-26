import AppKit
import CorralCore
import SwiftUI

/// Configures the window for the solid "Linear" look: opaque, near-black base,
/// transparent titlebar (paired with the hidden title-bar window style).
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            // Linear is solid — opaque window on the near-black base (no vibrancy).
            window.isOpaque = true
            window.backgroundColor = NSColor(srgbRed: 0x0B / 255, green: 0x0B / 255, blue: 0x0D / 255, alpha: 1)
            window.titlebarAppearsTransparent = true
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// The corral design language: a single, deliberately-designed dark theme
// (a terminal product should own its palette rather than inherit the system's).
// One accent, a semantic status-color set, an 8pt spacing rhythm.
enum Theme {
    // "Linear" direction: a warm near-black owned palette. Regions are defined by
    // hairline borders (not glow or gradient); one desaturated-indigo accent, used
    // sparingly; a quiet semantic status set. Restraint and precision over effect.
    static let base = Color(hex: 0x0B0B0D)        // window / content backdrop
    static let sidebar = Color(hex: 0x0E0E11)     // sidebar panel
    static let raised = Color(hex: 0x161619)      // hover fills, chips, sheets
    static let bar = Color(hex: 0x0D0D10)         // header / pane bars
    static let terminalBG = Color(hex: 0x101013)  // cohesive near-black (matches SwiftTerm bg)

    // Corner radii — tight and consistent (Linear precision).
    static let radiusRow: CGFloat = 6
    static let radiusPane: CGFloat = 7
    static let radiusCard: CGFloat = 8

    // Nearly-flat panel wash — Linear surfaces are solid, so keep this whisper-subtle.
    static let panelGradient = LinearGradient(
        colors: [Color(hex: 0x0E0E11), Color(hex: 0x0B0B0D)],
        startPoint: .top, endPoint: .bottom
    )
    static let topHighlight = Color.white.opacity(0.035)

    // Hairlines — the primary region-defining device.
    static let hairline = Color.white.opacity(0.065)
    static let hairlineStrong = Color.white.opacity(0.10)

    // Text hierarchy (slightly warm neutrals).
    static let textPrimary = Color(hex: 0xEEEEF1)
    static let textSecondary = Color(hex: 0x8B8B95)
    static let textTertiary = Color(hex: 0x54545E)

    // Desaturated indigo accent — selection, focus, the working pulse.
    static let accent = Color(hex: 0x7C86E0)

    // Quiet, desaturated status colors read more premium on a near-black ground.
    static func status(_ s: AgentStatus) -> Color {
        switch s {
        case .working: Color(hex: 0x5B9BF0)   // muted blue
        case .blocked: Color(hex: 0xE5636A)   // muted red (needs you)
        case .done: Color(hex: 0x4BBF7B)      // green
        case .idle: Color(hex: 0x63636D)      // muted grey
        case .unknown: Color(hex: 0x3A3A42)
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
