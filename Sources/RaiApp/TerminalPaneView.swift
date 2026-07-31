import AppKit
import RaiCore
import SwiftTerm
import SwiftUI
import UniformTypeIdentifiers

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
    case setAgentOverride
    case clearAgentOverride
    case releaseAgent
    case splitRight
    case splitDown
    case zoomPane
    case closePane
    case newTab
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

/// Collects the file URLs of a SwiftUI drop (NSItemProvider loading is async
/// and per-item) and delivers ONE escaped path line, in provider order.
///
/// The SwiftUI layer must claim file drops itself: the sidebar's reorder
/// `.onDrop` makes SwiftUI install its own AppKit dragging destination over
/// the whole window (`_PlatformDraggingDestinationView`), which wins the drop
/// before the terminal view's NSDraggingDestination is ever consulted.
enum FileDrop {
    /// Extensions Claude (and the clipboard) treat as images. A drop made
    /// entirely of these goes through the clipboard + Ctrl-V route so the
    /// pane shows [Image #N] immediately — exactly like pasting a screenshot.
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff",
    ]

    static func imageOnlyURLs(_ urls: [URL]) -> [URL]? {
        guard !urls.isEmpty,
              urls.allSatisfy({ imageExtensions.contains($0.pathExtension.lowercased()) })
        else { return nil }
        return urls
    }

    /// Collects the drop's file URLs (async, per-item) and hands them over
    /// in provider order on the main actor.
    static func deliverURLs(
        _ providers: [NSItemProvider],
        handle: @escaping @MainActor ([URL]) -> Void
    ) -> Bool {
        let candidates = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !candidates.isEmpty else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var urls = [URL?](repeating: nil, count: candidates.count)
        for (index, provider) in candidates.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                lock.lock()
                urls[index] = url
                lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let found = urls.compactMap { $0 }
            guard !found.isEmpty else { return }
            MainActor.assumeIsolated {
                handle(found)
            }
        }
        return true
    }

    static func deliver(
        _ providers: [NSItemProvider],
        send: @escaping @MainActor (String) -> Void
    ) -> Bool {
        deliverURLs(providers) { urls in
            send(DroppedPathEscaper.line(for: urls))
        }
    }
}

/// A terminal row is painted to its full width, so a copied line drags a
/// pty's worth of trailing spaces along (264 columns on a big display); in
/// any wrapping editor every pasted line then folds into a bonus blank row.
/// Rendering artifacts, not content — strip them per line.
enum CopiedText {
    static func trimmed(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                var l = line
                while let last = l.last, last == " " || last == "\t" || last == "\u{00A0}" {
                    l = l.dropLast()
                }
                return l
            }
            .joined(separator: "\n")
    }
}

/// Ghostty-parity escaping for paths dropped onto a terminal: backslash-escape
/// every character the shell (or Claude's @-path parsing) would otherwise
/// interpret, leaving common path characters readable.
enum DroppedPathEscaper {
    private static let safe = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+=:,@%")

    static func escape(_ path: String) -> String {
        String(path.flatMap { safe.contains($0) ? [$0] : ["\\", $0] })
    }

    static func line(for urls: [URL]) -> String {
        urls.map { escape($0.path) }.joined(separator: " ") + " "
    }
}

final class FocusAwareTerminalView: LocalProcessTerminalView {
    var onPlainClick: (() -> Void)?
    var onContextAction: ((PaneMenuAction) -> Void)?
    var agentDetectionSummary = "Herdr detects: No agent — Unknown"
    var canReleaseAgent = false
    private var draggedSinceMouseDown = false
    private var copiedPanel: NSPanel?
    private var scrolledPanel: NSPanel?
    private var copyModePanel: NSPanel?
    private var copyModeStatus: String?
    private var scrolledOffset = 0
    private var mouseIsDown = false
    private var frameObserverInstalled = false
    private var dragTypesRegistered = false

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
        let detectionItem = NSMenuItem(
            title: agentDetectionSummary,
            action: nil,
            keyEquivalent: ""
        )
        detectionItem.isEnabled = false
        menu.addItem(detectionItem)
        menu.addItem(contextItem("Set Pane Agent…", #selector(menuSetAgentOverride)))
        menu.addItem(contextItem("Clear Agent Override", #selector(menuClearAgentOverride)))
        let releaseItem = contextItem("Release Rai Agent Claim", #selector(menuReleaseAgent))
        releaseItem.isEnabled = canReleaseAgent
        menu.addItem(releaseItem)
        menu.addItem(.separator())
        let copyModeItem = contextItem(
            "Copy Mode", #selector(menuCopyMode), "c", [.command, .shift])
        copyModeItem.isEnabled = paneID != nil
        menu.addItem(copyModeItem)
        let editorItem = contextItem(
            "Edit Scrollback", #selector(menuEditScrollback), "e", [.command, .shift])
        editorItem.isEnabled = paneID != nil
        menu.addItem(editorItem)
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

    @objc private func menuSetAgentOverride() { onContextAction?(.setAgentOverride) }
    @objc private func menuClearAgentOverride() { onContextAction?(.clearAgentOverride) }
    @objc private func menuReleaseAgent() { onContextAction?(.releaseAgent) }
    @objc private func menuSplitRight() { onContextAction?(.splitRight) }
    @objc private func menuSplitDown() { onContextAction?(.splitDown) }
    @objc private func menuZoomPane() { onContextAction?(.zoomPane) }
    @objc private func menuClosePane() { onContextAction?(.closePane) }
    @objc private func menuNewTab() { onContextAction?(.newTab) }
    @objc private func menuCopyMode() { scrollbackSelection.enterCopyMode() }
    @objc private func menuEditScrollback() { scrollbackSelection.openScrollbackInEditor() }

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
            scrollbackSelection.onCopyModeStatusChanged = { [weak self] status in
                self?.showCopyModeStatus(status)
            }
            scrollbackSelection.onNotice = { [weak self] message in
                self?.showToast(message)
            }
        }
    }

    // SwiftTerm's keyDown is `public` (not `open`), so we can't override it from
    // this module. Instead an app-wide key monitor (installed in AppDelegate) calls
    // this on the focused terminal; returning true means we sent bytes to the PTY
    // and the monitor should swallow the event so SwiftTerm doesn't also handle it.
    func handleInterceptedKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        if let command = KeyRoutingDecision.terminalCommand(
            keyCode: event.keyCode,
            characters: event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            command: flags.contains(.command),
            option: flags.contains(.option),
            control: flags.contains(.control),
            shift: flags.contains(.shift),
            copyModeActive: scrollbackSelection.isCopyModeActive
        ) {
            switch command {
            case .enterCopyMode:
                scrollbackSelection.enterCopyMode()
            case .editScrollback:
                scrollbackSelection.openScrollbackInEditor()
            case .copyMode(let key):
                _ = scrollbackSelection.handleCopyModeKey(key)
            }
            return true
        }
        if scrollbackSelection.isCopyModeActive {
            // Command chords stay available to AppKit. Other keys cannot reach the PTY.
            return !flags.contains(.command)
        }

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
            NSPasteboard.general.setString(CopiedText.trimmed(text), forType: .string)
            showCopiedToast()
            return
        }
        if let selected = getSelection(), !selected.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(CopiedText.trimmed(selected), forType: .string)
            return
        }
        super.copy(sender)
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(CopiedText.trimmed(text), forType: .string)
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
        showToast("Copied to clipboard")
    }

    private func showToast(_ text: String) {
        copiedPanel?.orderOut(nil)
        guard let win = window else { return }

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

    // MARK: file drop → path insertion (Ghostty parity)

    // SwiftTerm has no NSDraggingDestination support, so without this a file
    // dragged from Finder onto a pane is simply rejected. Ghostty (and
    // Terminal.app) type the escaped path into the pty; do the same.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFileURLs(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedFileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        // Focus follows the drop: the paths land in this pane's pty, so the
        // pane should become the selected one, exactly like a click.
        onPlainClick?()
        window?.makeFirstResponder(self)
        send(txt: DroppedPathEscaper.line(for: urls))
        return true
    }

    private func droppedFileURLs(from sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
    }

    // MARK: "back to live" pill

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if !dragTypesRegistered {
            dragTypesRegistered = true
            registerForDraggedTypes([.fileURL])
        }
        // Pooled views move between windows/containers; keep the pill (a child
        // panel of the OLD window) from lingering over unrelated content.
        updateScrolledPill()
        if copyModeStatus != nil {
            showCopyModeStatus(copyModeStatus)
        }
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
        installGeometryObserver()
    }

    private func hideScrolledPill() {
        guard let panel = scrolledPanel else { return }
        panel.alphaValue = 0
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    @objc private func paneGeometryChanged() {
        if scrolledPanel?.parent != nil { updateScrolledPill() }
        if copyModePanel?.parent != nil { positionCopyModePanel() }
    }

    private func installGeometryObserver() {
        guard !frameObserverInstalled else { return }
        frameObserverInstalled = true
        postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(paneGeometryChanged),
            name: NSView.frameDidChangeNotification,
            object: self
        )
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

    /// Copy mode must stay visible above the terminal's Metal layer.
    private func showCopyModeStatus(_ status: String?) {
        copyModeStatus = status
        if let panel = copyModePanel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        copyModePanel = nil
        guard let status, let win = window else { return }

        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let size = (status as NSString).size(withAttributes: [.font: font])
        let padX: CGFloat = 12
        let padY: CGFloat = 6
        let width = ceil(size.width) + padX * 2
        let height = ceil(size.height) + padY * 2

        let pill = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor(
            calibratedRed: 0.28,
            green: 0.18,
            blue: 0.42,
            alpha: 0.96
        ).cgColor
        pill.layer?.cornerRadius = 6

        let label = NSTextField(labelWithString: status)
        label.font = font
        label.textColor = .white
        label.frame = NSRect(
            x: padX,
            y: padY,
            width: ceil(size.width),
            height: ceil(size.height)
        )
        pill.addSubview(label)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.contentView = pill
        win.addChildWindow(panel, ordered: .above)
        copyModePanel = panel
        positionCopyModePanel()
        installGeometryObserver()
    }

    private func positionCopyModePanel() {
        guard let panel = copyModePanel, let win = window else { return }
        let topY = isFlipped ? bounds.minY + 14 : bounds.maxY - 14
        let point = win.convertPoint(
            toScreen: convert(NSPoint(x: bounds.midX, y: topY), to: nil)
        )
        panel.setFrameOrigin(NSPoint(
            x: point.x - panel.frame.width / 2,
            y: point.y - panel.frame.height
        ))
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
    var agentDetectionSummary = "Herdr detects: No agent — Unknown"
    var canReleaseAgent = false
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
        // nil once herdr has dropped the terminal: this is the outgoing
        // container of a pane that just closed, and it is on its way out too.
        guard let view = pool.view(for: terminalID) else { return }
        view.onPlainClick = onPlainClick
        view.onContextAction = onContextAction
        view.agentDetectionSummary = agentDetectionSummary
        view.canReleaseAgent = canReleaseAgent
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

    /// Creation order, used to arbitrate which container owns a pooled
    /// terminal. Relaying a tab (split, close, swap, zoom) makes SwiftUI build
    /// the replacement container *before* it tears the outgoing one down, so a
    /// higher serial always means "the newer, live host".
    private static var nextSerial = 0
    private let serial: Int

    /// The terminal this container currently hosts, for tests.
    var hostedTerminalView: FocusAwareTerminalView? { terminalView }

    override init(frame: NSRect) {
        serial = Self.nextSerial
        Self.nextSerial += 1
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func install(_ view: FocusAwareTerminalView) {
        if view.superview === self {
            terminalView = view
            return
        }
        // SwiftUI updates the outgoing container one last time *after* the
        // replacement has already adopted the pooled terminal. Letting that
        // final update steal the view back left it parented to a container
        // about to be dismantled — `detach()` then pulled it out of the window
        // entirely and the live pane stayed blank forever, because SwiftUI had
        // no reason to update the surviving container again. A newer host wins.
        if let host = view.superview as? TerminalContainerView, host.serial > serial {
            return
        }
        adopt(view)
    }

    private func adopt(_ view: FocusAwareTerminalView) {
        detach()
        // Exactly one container claims a terminal: leaving the previous host
        // pointing at it would let that host's `layout()` re-adopt it later.
        (view.superview as? TerminalContainerView)?.terminalView = nil
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

    /// Safety net: a pooled terminal that ends up parented nowhere (an
    /// outgoing container that pulled it out, an eviction that raced a
    /// relayout) can only be re-hosted here, because SwiftUI will not
    /// necessarily update this representable again. Layout is the one callback
    /// that is guaranteed to run while this container is on screen.
    override func layout() {
        if let terminalView, terminalView.superview == nil, window != nil {
            adopt(terminalView)
        }
        super.layout()
    }
}
