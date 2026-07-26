import AppKit
import RaiCore
import SwiftTerm
import SwiftUI

/// Resolves the `herdr` CLI, which rai spawns per pane to bridge the remote
/// terminal. A GUI app launched via LaunchServices gets a minimal PATH, so we
/// can't rely on `herdr` being resolvable by name.
/// Mirrors Yogev's Ghostty theme (`theme = Dracula+`) so agent sessions render
/// with identical colors in rai. Snapshot of the resolved Ghostty palette.
enum GhosttyTheme {
    static let background: UInt32 = 0x212121
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

    // SwiftTerm's keyDown is `public` (not `open`), so we can't override it from
    // this module. Instead an app-wide key monitor (installed in AppDelegate) calls
    // this on the focused terminal; returning true means we sent bytes to the PTY
    // and the monitor should swallow the event so SwiftTerm doesn't also handle it.
    func handleInterceptedKey(_ event: NSEvent) -> Bool {
        // Ghostty line-editing parity — the same ⌘/⌥ combos Yogev's Ghostty sends,
        // so muscle memory works in Claude/shell.
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        var bytes: [UInt8]?
        switch event.keyCode {
        case 51:  // delete / backspace
            if mods == .command { bytes = [0x15] }             // ⌘⌫ → Ctrl-U (kill to line start)
            else if mods == .option { bytes = [0x17] }         // ⌥⌫ → Ctrl-W (delete word)
        case 123: // left arrow
            if mods == .command { bytes = [0x01] }             // ⌘← → Ctrl-A (line start)
            else if mods == .option { bytes = [0x1b, 0x62] }   // ⌥← → ESC b (word back)
        case 124: // right arrow
            if mods == .command { bytes = [0x05] }             // ⌘→ → Ctrl-E (line end)
            else if mods == .option { bytes = [0x1b, 0x66] }   // ⌥→ → ESC f (word forward)
        case 36:  // return
            if mods == .shift { bytes = [0x1b, 0x0d] }         // ⇧⏎ → ESC CR (Claude newline)
        default:
            break
        }
        if let bytes {
            send(bytes)
            return true
        }

        // Non-ASCII text input (Hebrew, emoji, …). In apps that enable the kitty
        // keyboard protocol (Claude Code), SwiftTerm encodes the keystroke as a
        // key-event keyed on the base-layout glyph and the actual text is lost.
        // Send the literal UTF-8 ourselves, exactly as Ghostty does for text.
        let textMods = event.modifierFlags.intersection([.command, .control, .option, .function])
        if textMods.isEmpty, let chars = event.characters, !chars.isEmpty,
           chars.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }),
           chars.unicodeScalars.contains(where: { $0.value > 0x7f }) {
            send(txt: chars)
            return true
        }

        return false
    }

    // SwiftTerm's paste only reads clipboard text. When the clipboard holds an
    // image (no text), send Ctrl-V so the running program's own image paste fires
    // — Claude Code reads the clipboard image directly on Ctrl-V. This makes ⌘V
    // attach images too, matching Claude's "ctrl+v to paste" affordance.
    override func paste(_ sender: Any) {
        let clipboard = NSPasteboard.general
        if clipboard.string(forType: .string) == nil,
           clipboard.canReadObject(forClasses: [NSImage.self], options: nil) {
            send([0x16])  // Ctrl-V
            return
        }
        super.paste(sender)
    }

    // Text input (including Hebrew) arrives here via the input context. In apps
    // that enable the kitty keyboard protocol (Claude Code), SwiftTerm re-encodes
    // it and loses non-ASCII text — so send non-ASCII as literal UTF-8 like Ghostty.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        switch string {
        case let s as String: text = s
        case let s as NSAttributedString: text = s.string
        default:
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        if !text.isEmpty,
           text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }),
           text.unicodeScalars.contains(where: { $0.value > 0x7f }) {
            send(txt: text)
            return
        }
        super.insertText(string, replacementRange: replacementRange)
    }

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
        } else if !isFocused, view.window?.firstResponder === view {
            // Give up first responder (e.g. while the command palette is open) so a
            // SwiftUI TextField can take keyboard focus instead of the terminal.
            DispatchQueue.main.async { [weak view] in
                guard let view, view.window?.firstResponder === view else { return }
                view.window?.makeFirstResponder(nil)
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
