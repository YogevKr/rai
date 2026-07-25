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
    static let background: UInt32 = 0x212121
    static let foreground: UInt32 = 0xF8F8F2
    static let cursor: UInt32 = 0xF8F8F2
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
        view.selectedTextBackgroundColor = ns(selectionBackground)
        view.selectedTextForegroundColor = ns(selectionForeground)
        view.installColors(palette.map(st))
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

/// A real interactive terminal for a herdr pane.
///
/// Instead of polling `pane.read` snapshots (which can't type, select, or scroll),
/// this hosts `herdr terminal attach <terminal_id> --takeover` inside SwiftTerm's
/// `LocalProcessTerminalView`. SwiftTerm owns keyboard input, selection,
/// scrollback and resize on a real PTY; herdr's own attach client does the live
/// remote bridging. We attach by TERMINAL id (not pane id) via `terminal attach`
/// — `agent attach` only resolves panes that have a detected agent, so a bare
/// shell (e.g. a fresh ⌘T tab) errors "agent not found". The view is keyed by
/// terminal id upstream (`.id`), so switching agents tears this down and rebuilds.
struct TerminalPaneView: NSViewRepresentable {
    let terminalID: String
    let isFocused: Bool
    let onPlainClick: () -> Void

    // Matches Ghostty: `font-family = Fira Code`, `font-size = 16`.
    static let font = NSFont(name: "Fira Code", size: 16)
        ?? NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)

    func makeCoordinator() -> Coordinator {
        Coordinator(onPlainClick: onPlainClick)
    }

    func makeNSView(context: Context) -> FocusAwareTerminalView {
        let view = FocusAwareTerminalView(frame: .zero)
        view.font = Self.font
        GhosttyTheme.apply(to: view)
        // Prefer local text selection over mouse reporting: the attached TUIs
        // (Claude/Codex) enable mouse tracking, which would otherwise send drags
        // to the program instead of selecting. (Shift+drag still reports mouse.)
        view.allowMouseReporting = false
        view.processDelegate = context.coordinator
        view.onPlainClick = context.coordinator.requestFocus
        context.coordinator.attach(view, terminalID: terminalID)
        return view
    }

    func updateNSView(_ view: FocusAwareTerminalView, context: Context) {
        context.coordinator.onPlainClick = onPlainClick
        if isFocused, view.window?.firstResponder !== view {
            DispatchQueue.main.async { [weak view] in
                view?.window?.makeFirstResponder(view)
            }
        }
    }

    static func dismantleNSView(_ view: FocusAwareTerminalView, coordinator: Coordinator) {
        coordinator.detach(view)
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var onPlainClick: () -> Void
        private weak var view: LocalProcessTerminalView?
        private var terminalID = ""
        private var started = false
        private var intentionalStop = false
        private var retries = 0
        private let maxRetries = 5

        init(onPlainClick: @escaping () -> Void) {
            self.onPlainClick = onPlainClick
        }

        func requestFocus() {
            onPlainClick()
        }

        func attach(_ view: LocalProcessTerminalView, terminalID: String) {
            guard !started else { return }
            started = true
            self.view = view
            self.terminalID = terminalID
            launch()
        }

        private func launch() {
            guard let view else { return }
            var env = ProcessInfo.processInfo.environment
            env["TERM"] = "xterm-256color"
            let path = env["PATH"] ?? ""
            if !path.contains("/opt/homebrew/bin") {
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:"
                    + (path.isEmpty ? "/usr/bin:/bin" : path)
            }
            if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }

            view.startProcess(
                executable: HerdrCLI.binaryPath,
                args: ["terminal", "attach", terminalID, "--takeover"],
                environment: env.map { "\($0.key)=\($0.value)" }
            )
        }

        func detach(_ view: LocalProcessTerminalView) {
            intentionalStop = true
            view.terminate()
        }

        // If the attach client exits on its own (a startup race where the pane is
        // mid-transition, a transient daemon hiccup), reconnect rather than leaving
        // a frozen error frame. Backs off and gives up after a few tries so a
        // genuinely-closed pane doesn't loop forever.
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            guard !intentionalStop, retries < maxRetries else { return }
            retries += 1
            let delay = 0.4 * Double(retries)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let view = self.view, !self.intentionalStop else { return }
                view.getTerminal().resetToInitialState()
                self.launch()
            }
        }

        // Corral draws its own chrome; SwiftTerm forwards PTY resizes to the attach
        // client automatically, which is how herdr learns the new size.
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    }
}
