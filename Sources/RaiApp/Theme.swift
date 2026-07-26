import AppKit
import RaiCore
import SwiftUI

/// Configures the window for the solid "Linear" look: opaque, near-black base,
/// transparent titlebar (paired with the hidden title-bar window style).
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            // Solid, opaque window on the Ghostty-grey base (no vibrancy).
            window.isOpaque = true
            window.backgroundColor = NSColor(srgbRed: 0x1A / 255, green: 0x1A / 255, blue: 0x1A / 255, alpha: 1)
            window.titlebarAppearsTransparent = true
            // Let content fill under the title bar so the panes reach the very top.
            window.styleMask.insert(.fullSizeContentView)
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// The rai design language: a single, deliberately-designed dark theme
// (a terminal product should own its palette rather than inherit the system's).
// One accent, a semantic status-color set, an 8pt spacing rhythm.
enum Theme {
    // Colors match Yogev's Ghostty (Dracula+): neutral #212121-family surfaces,
    // #f8f8f2 text, Dracula+ accent/status hues. The Linear *layout* stays —
    // hairline-defined regions, tight radii, restraint — only the palette is Ghostty.
    static let base = Color(hex: 0x1A1A1A)        // window / content backdrop
    static let sidebar = Color(hex: 0x1F1F1F)     // sidebar panel
    static let raised = Color(hex: 0x2C2C2E)      // hover fills, chips, sheets
    static let bar = Color(hex: 0x1C1C1C)         // header / pane bars
    static let terminalBG = Color(hex: 0x212121)  // Ghostty Dracula+ bg (matches SwiftTerm)

    // Corner radii — tight and consistent (Linear precision).
    static let radiusRow: CGFloat = 6
    static let radiusPane: CGFloat = 7
    static let radiusCard: CGFloat = 8

    // Shared top-bar height so the sidebar header and the detail header (and their
    // hairline dividers) align exactly across the split.
    static let headerHeight: CGFloat = 56

    // A consistent top strip that clears the window controls (traffic lights +
    // sidebar toggle, ~28pt) without the big dead title-bar strip. Applied to both
    // columns so collapsing the sidebar only changes the main panel's width.
    static let contentTopInset: CGFloat = 30

    // Nearly-flat panel wash — surfaces are solid, so keep this whisper-subtle.
    static let panelGradient = LinearGradient(
        colors: [Color(hex: 0x1F1F1F), Color(hex: 0x1A1A1A)],
        startPoint: .top, endPoint: .bottom
    )
    static let topHighlight = Color.white.opacity(0.04)

    // Hairlines — the primary region-defining device.
    static let hairline = Color.white.opacity(0.07)
    static let hairlineStrong = Color.white.opacity(0.11)

    // Text hierarchy: Ghostty foreground + Dracula muted.
    static let textPrimary = Color(hex: 0xF8F8F2)   // Ghostty foreground
    static let textSecondary = Color(hex: 0x9EA0AD)
    static let textTertiary = Color(hex: 0x6272A4)  // Dracula comment

    // Dracula+ purple accent (palette 5) — selection, focus, the working pulse.
    static let accent = Color(hex: 0xC792EA)

    // Dracula+ status colors.
    static func status(_ s: AgentStatus) -> Color {
        switch s {
        case .working: Color(hex: 0x82AAFF)   // Dracula+ blue
        case .blocked: Color(hex: 0xFF5555)   // Dracula red (needs you)
        case .done: Color(hex: 0x50FA7B)      // Dracula green
        case .idle: Color(hex: 0x6272A4)      // Dracula comment
        case .unknown: Color(hex: 0x44475A)   // Dracula current line
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
