import AppKit
import RaiCore
import SwiftTerm
import SwiftUI

/// Resolves the `herdr` CLI, which rai spawns per pane to bridge the remote
/// terminal. A GUI app launched via LaunchServices gets a minimal PATH, so we
/// can't rely on `herdr` being resolvable by name.
/// Keeps SwiftTerm aligned with the active rai palette. Dark retains the exact
/// Ghostty Dracula+ ANSI colors; Light uses a legible matching ANSI set.
@MainActor
enum GhosttyTheme {
    private static let darkPalette: [UInt32] = [
        0x21222C, 0xFF5555, 0x50FA7B, 0xFFCB6B, 0x82AAFF, 0xC792EA, 0x8BE9FD, 0xF8F8F2,
        0x545454, 0xFF6E6E, 0x69FF94, 0xFFCB6B, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xF8F8F2,
    ]
    private static let lightPalette: [UInt32] = [
        0x30343B, 0xC9363E, 0x238636, 0x9A6700, 0x2563B9, 0x7651B2, 0x087F8C, 0xE8E8EC,
        0x687386, 0xE0525B, 0x2DA44E, 0xB58407, 0x3B7DDD, 0x9067C6, 0x1597A5, 0xFFFFFF,
    ]

    static func apply(to view: LocalProcessTerminalView) {
        let isDark = Theme.activeVariant == .dark
        let background = Theme.nsColor(.terminalBG)
        let foreground = Theme.nsColor(.textPrimary)
        view.nativeBackgroundColor = background
        view.nativeForegroundColor = foreground
        view.caretColor = ns(isDark ? 0xECEFF4 : 0x7651B2)
        view.caretTextColor = ns(isDark ? 0x282828 : 0xFAFAFC)
        view.selectedTextBackgroundColor = ns(isDark ? 0xF8F8F2 : 0xD9D0EA)
        view.selectedTextForegroundColor = ns(isDark ? 0x545454 : 0x202124)
        view.installColors((isDark ? darkPalette : lightPalette).map(st))
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
/// Pane-level operations offered by the terminal's right-click menu; the
/// SwiftUI layer maps them onto RaiModel actions.
enum PaneMenuAction {
    case splitRight, splitDown, zoomPane, closePane, newTab
}

/// When a pane's viewport is scrolled away from the live tail (an edge-drag
/// selection or a manual wheel leaves herdr scrolled), the pane silently looks
/// frozen — new output lands below the fold. A floating "back to live" pill
/// makes the state visible and offers the way out. Hidden while the mouse is
/// down: mid-drag the selection engine itself is doing the scrolling.
enum ScrolledPillDecision {
    static func shouldShow(offsetFromBottom: Int, mouseIsDown: Bool, inWindow: Bool) -> Bool {
        offsetFromBottom > 0 && !mouseIsDown && inWindow
    }
}

final class FocusAwareTerminalView: LocalProcessTerminalView {
    var onPlainClick: (() -> Void)?
    var onContextAction: ((PaneMenuAction) -> Void)?
    private var draggedSinceMouseDown = false
    private var copiedPanel: NSPanel?
    private var scrolledPanel: NSPanel?
    private var scrolledOffset = 0
    private var mouseIsDown = false
    private var frameObserverInstalled = false

    /// Right-click on the pane: select it (like cmux), then offer the pane
    /// controls. AppKit-native so it works over the Metal-backed terminal.
    override func menu(for event: NSEvent) -> NSMenu? {
        onPlainClick?()

        let menu = NSMenu()
        menu.autoenablesItems = false

        let copyItem = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        copyItem.target = self
        copyItem.isEnabled = selectionActive || scrollbackSelection.hasExtendedSelection
        menu.addItem(copyItem)

        let pasteItem = NSMenuItem(title: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        pasteItem.target = self
        menu.addItem(pasteItem)

        menu.addItem(.separator())
        menu.addItem(contextItem("Split Right", #selector(menuSplitRight), "d", [.command]))
        menu.addItem(contextItem("Split Down", #selector(menuSplitDown), "d", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(contextItem("Zoom Pane", #selector(menuZoomPane), "\r", [.command, .shift]))
        menu.addItem(contextItem("Close Pane", #selector(menuClosePane), "w", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(contextItem("New Tab", #selector(menuNewTab), "t", [.command]))
        return menu
    }

    private func contextItem(
        _ title: String,
        _ action: Selector,
        _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = []
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    @objc private func menuSplitRight() { onContextAction?(.splitRight) }
    @objc private func menuSplitDown() { onContextAction?(.splitDown) }
    @objc private func menuZoomPane() { onContextAction?(.zoomPane) }
    @objc private func menuClosePane() { onContextAction?(.closePane) }
    @objc private func menuNewTab() { onContextAction?(.newTab) }

    /// Extends drag-selections into herdr-side scrollback (see the controller).
    let scrollbackSelection = ScrollbackSelectionController()

    /// The herdr pane this terminal is attached to, for pane.read/snapshot.
    var paneID: String? {
        get { scrollbackSelection.paneID }
        set {
            if scrollbackSelection.paneID != newValue {
                scrolledOffset = 0
                updateScrolledPill()
            }
            scrollbackSelection.paneID = newValue
            scrollbackSelection.view = self
            scrollbackSelection.onScrollOffsetChanged = { [weak self] scroll in
                self?.scrolledOffset = scroll.offsetFromBottom
                self?.updateScrolledPill()
            }
        }
    }

    // SwiftTerm's keyDown is `public` (not `open`), so we can't override it from
    // this module. Instead an app-wide key monitor (installed in AppDelegate) calls
    // this on the focused terminal; returning true means we sent bytes to the PTY
    // and the monitor should swallow the event so SwiftTerm doesn't also handle it.
    func handleInterceptedKey(_ event: NSEvent) -> Bool {
        // Ghostty line-editing parity — the same ⌘/⌥ combos Ghostty sends,
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

    // SwiftTerm's paste only reads clipboard text, so an image (e.g. a screenshot)
    // pastes nothing. When the clipboard holds an image, send Ctrl-V: Claude Code
    // reads the clipboard image itself on Ctrl-V and attaches it as [image]. (We
    // can't reliably tell Claude from a plain shell — the app enables its keyboard
    // protocol before rai attaches, so terminal state doesn't reflect it — and
    // pasting into an agent is the overwhelmingly common case.)
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

    // Ghostty parity: selection must survive a program streaming output (Claude
    // re-renders constantly, and Ghostty pins selections to content instead of
    // dropping them). SwiftTerm clears the selection on every feed *and* every
    // linefeed while `allowMouseReporting` is true, and the feed-side clear
    // (`feedPrepare`) is internal — not overridable. So the pool keeps
    // `allowMouseReporting = false` permanently: buttons always select locally
    // (plain drag, no Shift needed), and streaming never drops the selection.
    // The wheel must still reach mouse-mode TUIs (Claude scrolls its own
    // viewport), so AppDelegate's scroll monitor routes wheel events here with
    // reporting enabled just for that one synchronous dispatch. SwiftTerm's
    // `scrollWheel` is `public` (not `open`), hence the monitor instead of an
    // override — same story as `handleInterceptedKey` above.
    func handleInterceptedScroll(_ event: NSEvent) {
        allowMouseReporting = true
        scrollWheel(with: event)
        allowMouseReporting = false
        // Keep a finalized selection glued to its text while content scrolls.
        scrollbackSelection.noteWheel()
    }

    override func mouseDown(with event: NSEvent) {
        draggedSinceMouseDown = false
        mouseIsDown = true
        updateScrolledPill()
        scrollbackSelection.mouseDown()
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        draggedSinceMouseDown = true
        let point = convert(event.locationInWindow, from: nil)
        // Unflipped view: y grows upward — above bounds.maxY is past the TOP.
        let edge: ScrollbackSelectionController.EdgeDirection?
        let distance: CGFloat
        if point.y > bounds.maxY {
            edge = .up; distance = point.y - bounds.maxY
        } else if point.y < bounds.minY {
            edge = .down; distance = bounds.minY - point.y
        } else {
            edge = nil; distance = 0
        }
        let clamped = CGPoint(x: point.x, y: min(max(point.y, bounds.minY), bounds.maxY))
        let cell = cellPosition(at: clamped)

        if scrollbackSelection.engaged {
            // The scrollback engine owns the gesture: SwiftTerm's own drag
            // logic would fight the externally-scrolled highlight.
            scrollbackSelection.dragUpdate(
                edge: edge, distance: distance,
                visibleRow: cell.row, visibleCol: cell.col
            )
            return
        }
        super.mouseDragged(with: event)
        if edge != nil, selectionActive {
            scrollbackSelection.dragUpdate(
                edge: edge, distance: distance,
                visibleRow: cell.row, visibleCol: cell.col
            )
        } else {
            scrollbackSelection.dragUpdate(
                edge: nil, distance: 0,
                visibleRow: cell.row, visibleCol: cell.col
            )
        }
    }

    override func mouseUp(with event: NSEvent) {
        mouseIsDown = false
        defer { updateScrolledPill() }
        let wasPlainClick = !draggedSinceMouseDown
        let copyOnSelect = SettingsStore.shared.copyOnSelect
        if scrollbackSelection.engaged {
            let assembled = scrollbackSelection.finishGesture(copyOnSelect: copyOnSelect)
            super.mouseUp(with: event)
            if copyOnSelect, let assembled, !assembled.isEmpty {
                copyToClipboard(assembled)
            }
            // Ghostty-style (default): highlight + model stay for ⌘C.
            return
        }
        super.mouseUp(with: event)
        if wasPlainClick {
            onPlainClick?()
        } else if copyOnSelect, let selected = getSelection(), !selected.isEmpty {
            // herdr-style gesture (Settings → Terminal → Copy on select):
            // finishing a drag copies it; the highlight lingers, then clears.
            copyToClipboard(selected)
        } else if selectionActive {
            // Ghostty-style sticky selection: anchor it to content so
            // scrolling doesn't drag the highlight onto different text.
            scrollbackSelection.captureStickySelection()
        }
    }

    /// ⌘C. When the scrollback engine holds a selection wider than the screen,
    /// copy the assembled multi-page text instead of the visible slice.
    override func copy(_ sender: Any) {
        if scrollbackSelection.hasExtendedSelection,
           let text = scrollbackSelection.assembledText(), !text.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            showCopiedToast()
            return
        }
        super.copy(sender)
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showCopiedToast()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.selectNone()
        }
    }

    /// A small "Copied to clipboard" pill that fades in near the pane's bottom
    /// and fades out on its own — the same confirmation herdr shows. It lives in
    /// a floating child NSPanel because the terminal renders through a
    /// CAMetalLayer that paints over any in-view subview or SwiftUI overlay.
    private func showCopiedToast() {
        copiedPanel?.orderOut(nil)
        guard let win = window else { return }

        let text = "Copied to clipboard"
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let ts = (text as NSString).size(withAttributes: [.font: font])
        let padX: CGFloat = 11, padY: CGFloat = 5
        let w = ceil(ts.width) + padX * 2, h = ceil(ts.height) + padY * 2

        let pill = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
        pill.layer?.cornerRadius = 6
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = .white
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.frame = NSRect(x: padX, y: padY, width: ceil(ts.width), height: ceil(ts.height))
        pill.addSubview(label)

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.contentView = pill

        // Anchor at the pane's visual bottom-center, in screen coordinates.
        let bottomY = isFlipped ? bounds.maxY - 48 : bounds.minY + 48
        let inScreen = win.convertPoint(toScreen: convert(NSPoint(x: bounds.midX, y: bottomY), to: nil))
        panel.setFrameOrigin(NSPoint(x: inScreen.x - w / 2, y: inScreen.y - h / 2))
        win.addChildWindow(panel, ordered: .above)
        copiedPanel = panel

        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak panel] in
            guard let panel else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.35; panel.animator().alphaValue = 0 },
                completionHandler: {
                    panel.parent?.removeChildWindow(panel)
                    panel.orderOut(nil)
                })
        }
    }

    // MARK: "back to live" pill

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Pooled views move between windows/containers; keep the pill (a child
        // panel of the OLD window) from lingering over unrelated content.
        updateScrolledPill()
    }

    private func updateScrolledPill() {
        if ScrolledPillDecision.shouldShow(
            offsetFromBottom: scrolledOffset, mouseIsDown: mouseIsDown,
            inWindow: window != nil
        ) {
            showScrolledPill()
        } else {
            hideScrolledPill()
        }
    }

    /// Same floating-child-panel trick as the copied toast (the Metal layer
    /// paints over in-view subviews), but persistent and clickable.
    private func showScrolledPill() {
        guard let win = window else { return }
        let panel = scrolledPanel ?? makeScrolledPill()
        scrolledPanel = panel
        if panel.parent !== win {
            panel.parent?.removeChildWindow(panel)
            win.addChildWindow(panel, ordered: .above)
        }
        // Bottom-right of the pane, inset so it clears the scroller edge.
        let size = panel.frame.size
        let inset: CGFloat = 12
        let bottomY = isFlipped ? bounds.maxY - inset : bounds.minY + inset
        let corner = win.convertPoint(
            toScreen: convert(NSPoint(x: bounds.maxX - inset, y: bottomY), to: nil))
        panel.setFrameOrigin(NSPoint(x: corner.x - size.width, y: corner.y))
        if panel.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        }
        if !frameObserverInstalled {
            frameObserverInstalled = true
            postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(paneGeometryChanged),
                name: NSView.frameDidChangeNotification, object: self)
        }
    }

    private func hideScrolledPill() {
        guard let panel = scrolledPanel else { return }
        panel.alphaValue = 0
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    @objc private func paneGeometryChanged() {
        if scrolledPanel?.parent != nil { updateScrolledPill() }
    }

    @objc private func scrolledPillClicked() {
        scrollbackSelection.returnToLive()
    }

    private func makeScrolledPill() -> NSPanel {
        let text = "↓ Back to live"
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let ts = (text as NSString).size(withAttributes: [.font: font])
        let padX: CGFloat = 11, padY: CGFloat = 5
        let w = ceil(ts.width) + padX * 2, h = ceil(ts.height) + padY * 2

        let pill = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
        pill.layer?.cornerRadius = 6
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = .white
        label.frame = NSRect(x: padX, y: padY, width: ceil(ts.width), height: ceil(ts.height))
        pill.addSubview(label)
        pill.addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(scrolledPillClicked)))

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.contentView = pill
        panel.alphaValue = 0
        return panel
    }

}

/// A lightweight host for a pooled, interactive herdr terminal.
///
/// The container follows SwiftUI's lifecycle, while `TerminalPool` owns the
/// SwiftTerm view and its live `herdr terminal attach` process. Moving the pooled
/// view between containers preserves its terminal contents and process.
struct TerminalPaneView: NSViewRepresentable {
    let terminalID: String
    var paneID: String?
    let isFocused: Bool
    let pool: TerminalPool
    let onPlainClick: () -> Void
    var onContextAction: (PaneMenuAction) -> Void = { _ in }

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
        view.onContextAction = onContextAction
        view.paneID = paneID
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
