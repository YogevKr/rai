import AppKit
import CorralCore
import SwiftTerm
import SwiftUI

/// Resolves the `herdr` CLI, which corral spawns per pane to bridge the remote
/// terminal. A GUI app launched via LaunchServices gets a minimal PATH, so we
/// can't rely on `herdr` being resolvable by name.
/// Mirrors Yogev's Ghostty theme (`theme = Dracula+`) so agent sessions render
/// with identical colors in corral. Snapshot of the resolved Ghostty palette.
enum GhosttyTheme {
    // Terminal bg darkened from Ghostty's 0x212121 to sit cohesively on the Linear
    // near-black chrome; the Dracula+ ANSI palette + cursor stay true to Ghostty.
    static let background: UInt32 = 0x101013
    static let foreground: UInt32 = 0xF8F8F2
    static let cursor: UInt32 = 0xECEFF4       // Ghostty `cursor-color`
    static let cursorText: UInt32 = 0x282828   // Ghostty `cursor-text` (block cursor)
    static let selectionBackground: UInt32 = 0xF8F8F2
    static let selectionForeground: UInt32 = 0x545454
    // ANSI 0–15 (normal then bright).
    static let palette: [UInt32] = [
        0x21222C, 0xFF5555, 0x50FA7B, 0xFFCB6B, 0x82AAFF, 0xC792EA, 0x8BE9FD, 0xF8F8F2,
        0x545454, 0xFF6E6E, 0x69FF94, 0xFFCB6B, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xF8F8F2,
    ]

    static func apply(to view: LocalProcessTerminalView) {
        view.nativeBackgroundColor = ns(background)
        view.nativeForegroundColor = ns(foreground)
        view.caretColor = ns(cursor)
        view.caretTextColor = ns(cursorText)
        view.selectedTextBackgroundColor = ns(selectionBackground)
        view.selectedTextForegroundColor = ns(selectionForeground)
        view.installColors(palette.map(st))
        // Ghostty `cursor-style = bar`, `cursor-style-blink = false`. This sets the
        // default; programs can still override via DECSCUSR, exactly as Ghostty does.
        view.getTerminal().setCursorStyle(.steadyBar)
    }

    private static func ns(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    private static func st(_ hex: UInt32) -> SwiftTerm.Color {
        func comp(_ shift: UInt32) -> UInt16 { UInt16((hex >> shift) & 0xFF) &* 257 }
        return SwiftTerm.Color(red: comp(16), green: comp(8), blue: comp(0))
    }
}

enum HerdrCLI {
    static let binaryPath: String = {
        if let env = ProcessInfo.processInfo.environment["HERDR_BIN_PATH"],
           !env.isEmpty, FileManager.default.isExecutableFile(atPath: env) {
            return env
        }
        let candidates = [
            "/opt/homebrew/bin/herdr",
            "/usr/local/bin/herdr",
            NSHomeDirectory() + "/.local/bin/herdr",
            "/usr/bin/herdr",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "/opt/homebrew/bin/herdr"
    }()
}

/// Reports a completed click without intercepting SwiftTerm's mouse handling.
/// SwiftTerm still receives every down/drag/up event, so selection, links, and
/// terminal mouse-reporting behavior remain unchanged.
final class FocusAwareTerminalView: LocalProcessTerminalView {
    var onPlainClick: (() -> Void)?
    private var draggedSinceMouseDown = false

    override func mouseDown(with event: NSEvent) {
        draggedSinceMouseDown = false
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        draggedSinceMouseDown = true
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let wasPlainClick = !draggedSinceMouseDown
        super.mouseUp(with: event)
        if wasPlainClick {
            onPlainClick?()
        }
    }

}

/// A lightweight host for a pooled, interactive herdr terminal.
///
/// The container follows SwiftUI's lifecycle, while `TerminalPool` owns the
/// SwiftTerm view and its live `herdr terminal attach` process. Moving the pooled
/// view between containers preserves its terminal contents and process.
struct TerminalPaneView: NSViewRepresentable {
    let terminalID: String
    let isFocused: Bool
    let pool: TerminalPool
    let onPlainClick: () -> Void

    static var font: NSFont {
        let settings = SettingsStore.shared
        let size = CGFloat(settings.terminalFontSize)
        return NSFontManager.shared.font(
            withFamily: settings.terminalFontFamily,
            traits: [],
            weight: 5,
            size: size
        )
            ?? NSFont(name: settings.terminalFontFamily, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func makeNSView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView(frame: .zero)
        update(container)
        return container
    }

    func updateNSView(_ container: TerminalContainerView, context: Context) {
        update(container)
    }

    private func update(_ container: TerminalContainerView) {
        let view = pool.view(for: terminalID)
        view.onPlainClick = onPlainClick
        container.install(view)
        if isFocused, view.window?.firstResponder !== view {
            DispatchQueue.main.async { [weak container, weak view] in
                guard let container, let view, view.superview === container else { return }
                view.window?.makeFirstResponder(view)
            }
        }
    }

    static func dismantleNSView(_ container: TerminalContainerView, coordinator: Void) {
        container.detach()
    }
}

@MainActor
final class TerminalContainerView: NSView {
    private weak var terminalView: FocusAwareTerminalView?

    func install(_ view: FocusAwareTerminalView) {
        guard terminalView !== view || view.superview !== self else { return }
        detach()
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        terminalView = view
    }

    func detach() {
        guard let terminalView else { return }
        if terminalView.superview === self {
            terminalView.removeFromSuperview()
        }
        self.terminalView = nil
    }
}
