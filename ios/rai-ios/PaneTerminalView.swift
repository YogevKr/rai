import RaiCore
import PhotosUI
import SwiftTerm
import SwiftUI
import UIKit

struct PaneTerminalView: View {
    let pane: Pane
    @ObservedObject var connection: BridgeConnection
    @State private var composedLine = ""
    @State private var isSearching = false
    @State private var searchText = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isSendingImage = false
    @State private var imageError: String?
    @State private var showingCommandPalette = false
    @State private var destructiveArmed = false
    @FocusState private var composeFocused: Bool
    @StateObject private var terminalSearch = TerminalSearchController()
    @StateObject private var promptController = TerminalPromptController()

    var body: some View {
        StreamingTerminalView(
            paneID: pane.paneID,
            connection: connection,
            search: terminalSearch,
            prompts: promptController,
            agent: pane.agent,
            beacon: pane.beacon,
            send: { connection.sendInput($0, to: pane.paneID) }
        )
        // Breathing room between the last terminal row and the compose
        // bar / keyboard stack; padding sits inside the background so the
        // gap stays terminal-colored.
        .padding(.bottom, 2)
        .background(Color(red: 33 / 255, green: 33 / 255, blue: 33 / 255))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The bar stack is one bottom safe-area inset, not the tail of a
        // VStack. As plain stack children the rows below the compose field
        // slid under the keyboard when that field took focus — the terminal
        // key row disappeared — so the stack changed height depending on which
        // view held the keyboard. An inset rides above the keyboard either
        // way: rai's compose field, or SwiftTerm's terminal view (which brings
        // its own esc/ctrl accessory bar).
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if isSearching {
                    HStack(spacing: 8) {
                        TextField("Find in scrollback", text: $searchText)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .onSubmit { terminalSearch.next(searchText) }
                            .onChange(of: searchText) { _, query in
                                terminalSearch.search(query)
                            }
                        Text(terminalSearch.summary)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 36)
                        Button { terminalSearch.previous(searchText) } label: {
                            Image(systemName: "chevron.up")
                        }
                        .disabled(searchText.isEmpty)
                        Button { terminalSearch.next(searchText) } label: {
                            Image(systemName: "chevron.down")
                        }
                        .disabled(searchText.isEmpty)
                        Button {
                            isSearching = false
                            terminalSearch.clear()
                        } label: {
                            Image(systemName: "xmark")
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.bar)
                }

                if let prompt = promptController.prompt,
                   ClaudePromptGate.allows(agent: pane.agent, beacon: pane.beacon) {
                    PromptBar(
                        prompt: prompt,
                        isBusy: promptController.isBusy,
                        select: { option in
                            let sendKey: (String) -> Void = {
                                connection.sendKeys([$0], to: pane.paneID)
                            }
                            if prompt.kind == .numberedPermission {
                                promptController.sendLegacy(
                                    renderedPrompt: prompt,
                                    option: option,
                                    through: { bytes in
                                        sendKey(String(decoding: bytes, as: UTF8.self))
                                    }
                                )
                            } else {
                                promptController.select(
                                    renderedPrompt: prompt,
                                    option: option,
                                    through: sendKey
                                )
                            }
                        },
                        advance: {
                            promptController.advance(renderedPrompt: prompt) {
                                connection.sendKeys([$0], to: pane.paneID)
                            }
                        },
                        retreat: {
                            promptController.retreat(renderedPrompt: prompt) {
                                connection.sendKeys([$0], to: pane.paneID)
                            }
                        },
                        submit: {
                            promptController.submit(renderedPrompt: prompt) {
                                connection.sendKeys([$0], to: pane.paneID)
                            }
                        },
                        escape: {
                            promptController.sendEscape(
                                renderedPrompt: prompt,
                                through: { connection.sendInput($0, to: pane.paneID) }
                            )
                        },
                        dismiss: { promptController.dismiss(renderedPrompt: prompt) }
                    )
                }

                // Held lines are stated, not just kept. A queue the user cannot
                // see is only marginally better than the silent drop it
                // replaced — they still cannot tell whether the Mac got it.
                if !connection.outbox.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                        Text(
                            connection.outbox.count == 1
                                ? "1 line waiting for a connection"
                                : "\(connection.outbox.count) lines waiting for a connection"
                        )
                        .font(.footnote)
                        Spacer()
                        Button("Discard", role: .destructive) {
                            connection.discardOutbox()
                        }
                        .font(.footnote)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .background(.bar)
                }

                HStack(spacing: 8) {
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        if isSendingImage {
                            ProgressView()
                        } else {
                            Image(systemName: "photo")
                        }
                    }
                    .disabled(isSendingImage)
                    .accessibilityLabel("Send photo")
                    if pane.agent != nil {
                        Button {
                            showingCommandPalette = true
                        } label: {
                            // A bare slash, sized to sit alongside the SF-symbol
                            // photo icon (there is no un-circled slash symbol).
                            Text("/")
                                .font(.title2.weight(.medium))
                        }
                        .accessibilityLabel("Slash commands")
                    }
                    TextField("Send a line…", text: $composedLine)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.send)
                        .onSubmit(sendComposedLine)
                        .focused($composeFocused)
                    // Messaging-app placement: Send sits in the compose row and
                    // stays there. It used to appear only while the field was
                    // unfocused — the theory being that the keyboard's blue ↑ was
                    // already the send — but that reshaped the row the moment you
                    // started typing and left no visible send target exactly while
                    // you were composing. The ↑ still sends; this is the second,
                    // always-present way. Destructive input still arms a red
                    // confirmation before it goes through.
                    Button(action: sendComposedLine) {
                        Image(
                            systemName: destructiveArmed
                                ? "exclamationmark.circle.fill"
                                : "arrow.up.circle.fill"
                        )
                        .font(.title)
                        .symbolRenderingMode(.hierarchical)
                    }
                    .disabled(composedLine.isEmpty)
                    .tint(destructiveArmed ? .red : nil)
                    .accessibilityLabel(destructiveArmed ? "Confirm send" : "Send")
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)

                if pane.agent != nil, promptController.prompt == nil {
                    QuickReplyRow { text in
                        sendLine(text)
                    }
                }

                TerminalControlToolbar { connection.sendInput($0, to: pane.paneID) }
            }
        }
        .navigationTitle(pane.terminalTitleStripped ?? pane.agent ?? "Pane")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    terminalSearch.toggleKeyboard()
                } label: {
                    Image(
                        systemName: terminalSearch.keyboardVisible
                            ? "keyboard.chevron.compact.down"
                            : "keyboard"
                    )
                }
                .accessibilityLabel(
                    terminalSearch.keyboardVisible
                        ? "Hide keyboard"
                        : "Type directly in terminal"
                )
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isSearching.toggle()
                    if !isSearching { terminalSearch.clear() }
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("Find in terminal")
            }
        }
        .onAppear {
            connection.openPane(paneID: pane.paneID)
            // Testing/automation affordance mirroring RAI_OPEN_PANE: put the
            // keyboard in the compose field so an end-to-end run can screenshot
            // the composing state without synthesizing a tap. Never set in
            // normal use.
            if ProcessInfo.processInfo.environment["RAI_FOCUS_COMPOSER"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    composeFocused = true
                }
            // Sibling affordance for the OTHER responder: the keyboard goes to
            // the pty, as it does for an agent-less pane. An agent pane cannot
            // reach that state without a tap on the toolbar keyboard button,
            // which left direct-mode behavior untestable end to end — and
            // direct mode on an IDLE agent pane is exactly where the pane's
            // bottom rows going missing was reproducible.
            } else if ProcessInfo.processInfo.environment["RAI_FOCUS_TERMINAL"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    terminalSearch.focusKeyboard()
                }
            // A plain terminal pane (no detected agent) is for typing: put the
            // keyboard straight into the pty. Agent panes keep the calmer
            // compose-bar default — the toolbar keyboard button opts in.
            } else if pane.agent == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    terminalSearch.focusKeyboard()
                }
            }
        }
        .onDisappear { connection.detachPane(paneID: pane.paneID) }
        .onChange(of: promptController.focusComposerRequest) { _, _ in
            composeFocused = true
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task { await sendPhoto(item) }
        }
        .sheet(isPresented: $showingCommandPalette) {
            CommandPaletteSheet(
                agent: pane.agent,
                insert: { composedLine = $0 },
                sendNow: { sendLine($0) }
            )
        }
        .alert(
            "Could Not Send Photo",
            isPresented: Binding(
                get: { imageError != nil },
                set: { if !$0 { imageError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(imageError ?? "")
        }
    }

    private func sendComposedLine() {
        let text = composedLine
        guard !text.isEmpty else { return }
        // Destructive shell input takes a second tap: the Send button turns
        // into a red "Sure?" for three seconds.
        if DestructiveInput.isDestructive(text), !destructiveArmed {
            destructiveArmed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                destructiveArmed = false
            }
            return
        }
        destructiveArmed = false
        // Clear only once the line is actually on the wire. It used to clear
        // unconditionally, so typing with no signal wiped the text and dropped
        // it — the send failure was swallowed into handleSocketFailure and the
        // user was never told. A queued line keeps the field's contents until
        // it lands.
        Task {
            let delivered = await connection.sendComposedLine(
                Array(text.utf8) + [0x0D], to: pane.paneID)
            if delivered { composedLine = "" }
        }
    }

    private func sendLine(_ text: String) {
        connection.sendInput(Array(text.utf8) + [0x0D], to: pane.paneID)
    }


    private func sendPhoto(_ item: PhotosPickerItem) async {
        isSendingImage = true
        defer {
            isSendingImage = false
            selectedPhoto = nil
        }
        do {
            guard let source = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: source),
                  let data = Self.sizedPNG(from: image)
            else {
                throw PhotoSendError.invalidImage
            }
            try await connection.sendImage(
                data,
                filename: "photo-\(Int(Date().timeIntervalSince1970)).png",
                to: pane.paneID
            )
        } catch {
            imageError = error.localizedDescription
        }
    }

    private static func sizedPNG(from source: UIImage) -> Data? {
        var image = source
        let maxDimension: CGFloat = 2_048
        let longest = max(image.size.width, image.size.height)
        if longest > maxDimension {
            image = image.resized(by: maxDimension / longest)
        }
        var data = image.pngData()
        while let current = data, current.count > 4 * 1_024 * 1_024,
              min(image.size.width, image.size.height) > 512 {
            image = image.resized(by: 0.75)
            data = image.pngData()
        }
        guard let data, data.count <= 5 * 1_024 * 1_024 else { return nil }
        return data
    }
}

/// The pane terminal's width contract. The 80-column width is a FLOOR, not a
/// fixed size: narrower viewports (portrait) scroll horizontally to reach the
/// full grid, wider ones (landscape) stretch the terminal edge-to-edge instead
/// of parking it left with a dead strip on the right.
enum TerminalPaneLayout {
    struct Built {
        let all: [NSLayoutConstraint]
        /// The `width >= minWidth` floor. Its constant grows past the 80-col
        /// base when the streamed grid is wider, so horizontal panning can
        /// reach every column of the remote pane.
        let widthFloor: NSLayoutConstraint
    }

    static func build(
        terminal: UIView, in scroll: UIScrollView, minWidth: CGFloat
    ) -> Built {
        let fill = terminal.widthAnchor.constraint(
            equalTo: scroll.frameLayoutGuide.widthAnchor)
        fill.priority = UILayoutPriority(999)   // yields to the floor below
        let floor = terminal.widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth)
        return Built(
            all: [
                terminal.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
                terminal.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
                terminal.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
                terminal.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
                fill,
                floor,
                terminal.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            ],
            widthFloor: floor
        )
    }

    static func constraints(
        terminal: UIView, in scroll: UIScrollView, minWidth: CGFloat
    ) -> [NSLayoutConstraint] {
        build(terminal: terminal, in: scroll, minWidth: minWidth).all
    }
}

private struct StreamingTerminalView: UIViewRepresentable {
    let paneID: String
    let connection: BridgeConnection
    let search: TerminalSearchController
    let prompts: TerminalPromptController
    let agent: String?
    let beacon: AgentBeacon?
    let send: ([UInt8]) -> Void

    // Render the pane at a faithful MINIMUM width (agent TUIs assume ~80 cols):
    // narrower screens (portrait) scroll horizontally rather than reflowing to
    // phone-width and mangling the layout; wider ones (landscape) grow the grid
    // so the TUI reflows to fill the screen.
    static let columns = 80
    private static let font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private static let background = ui(0x212121)
    private static let foreground = ui(0xF8F8F2)
    private static let palette: [UInt32] = [
        0x21222C, 0xFF5555, 0x50FA7B, 0xFFCB6B, 0x82AAFF, 0xC792EA, 0x8BE9FD, 0xF8F8F2,
        0x545454, 0xFF6E6E, 0x69FF94, 0xFFCB6B, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xF8F8F2,
    ]

    func makeCoordinator() -> Coordinator {
        Coordinator(
            paneID: paneID,
            connection: connection,
            search: search,
            prompts: prompts,
            send: send
        )
    }

    func makeUIView(context: Context) -> UIScrollView {
        let terminal = GridReadableTerminalView(frame: .zero, font: Self.font)
        terminal.terminalDelegate = context.coordinator
        terminal.nativeBackgroundColor = Self.background
        terminal.nativeForegroundColor = Self.foreground
        terminal.caretColor = Self.foreground
        terminal.caretTextColor = Self.background
        terminal.selectedTextBackgroundColor = Self.foreground
        terminal.selectedTextForegroundColor = Self.ui(0x545454)
        terminal.installColors(Self.palette.map(Self.st))
        terminal.indicatorStyle = .white
        // Dragging down through the terminal tucks the keyboard away, the
        // same gesture Messages and Notes use.
        terminal.keyboardDismissMode = .interactive
        terminal.translatesAutoresizingMaskIntoConstraints = false
        context.coordinator.terminal = terminal
        search.terminal = terminal
        prompts.readGrid = { [weak terminal] in
            terminal?.liveGridText() ?? ""
        }
        prompts.beacon = beacon
        prompts.allowsPrompts = ClaudePromptGate.allows(agent: agent, beacon: beacon)

        context.coordinator.scrollbackHandlerID = connection.addPaneScrollbackHandler(
            for: paneID
        ) { [weak terminal] data in
            // Remote history (herdr's `pane read --source recent`) seeds the
            // local buffer so the user can scroll up — agent TUIs live on the
            // alt screen and never produce scrollback via the frame stream.
            // A seed can also follow a reconnect, with stale grid content and
            // older history already in the buffer: full-reset first (ESC c
            // clears screen, modes, and scrollback) so the seed plus the
            // stream's next full frame rebuild one clean copy.
            terminal?.feed(byteArray: [0x1B, 0x63][...])
            terminal?.feed(byteArray: Self.normalizedHistory(data)[...])
        }

        context.coordinator.frameHandlerID = connection.addPaneFrameHandler(for: paneID) {
            [weak terminal] data, full, grid in
            // Newer Macs stream the pane's FULL grid and stamp each frame with
            // its dimensions. Pin the emulator to them so cell-addressed
            // paints land where herdr rendered them; when the grid is taller
            // or wider than the view (keyboard up, portrait), the view scrolls
            // over it instead of clipping the bottom rows — prompt included.
            if let grid {
                terminal?.pinGridSize(cols: grid.cols, rows: grid.rows)
                context.coordinator.updateWidthFloor(cols: grid.cols)
            }
            // A `full` frame starts a fresh stream (initial attach, or a restart
            // after resize/reconnect). Clear the visible screen + home the cursor
            // first so stale cells/styles from the previous stream don't bleed
            // through; scrollback above is preserved.
            if full {
                context.coordinator.prompts.invalidateForFullFrame()
                terminal?.feed(byteArray: [0x1B, 0x5B, 0x48, 0x1B, 0x5B, 0x32, 0x4A][...])
            }
            terminal?.feed(byteArray: [UInt8](data)[...])
            context.coordinator.prompts.refresh(frameArrived: true)
            if full {
                // A stream (re)start means "show me the live screen": follow
                // the cursor region (NOT the geometric bottom — a pinned grid
                // taller than its content has nothing but empty rows there).
                // Async so the feed's layout/contentSize update lands first.
                DispatchQueue.main.async { [weak terminal] in
                    terminal?.scrollToLive()
                    context.coordinator.prompts.refresh()
                }
            }
        }

        // Give the grid a `columns`-wide floor and host it in a horizontally-
        // scrolling view. The terminal keeps its own vertical scrollback; the
        // outer scroll view only moves left/right when the screen is narrower
        // than the floor (portrait).
        let charWidth = ("W" as NSString)
            .size(withAttributes: [.font: Self.font]).width
        let terminalWidth = ceil(charWidth * CGFloat(Self.columns)) + 4

        let scroll = UIScrollView()
        scroll.backgroundColor = Self.background
        scroll.showsHorizontalScrollIndicator = true
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceVertical = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.addSubview(terminal)
        let layout = TerminalPaneLayout.build(
            terminal: terminal, in: scroll, minWidth: terminalWidth)
        NSLayoutConstraint.activate(layout.all)
        context.coordinator.widthFloor = layout.widthFloor
        context.coordinator.baseWidthFloor = terminalWidth
        context.coordinator.charWidth = charWidth
        return scroll
    }


    private static func ui(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    private static func st(_ hex: UInt32) -> SwiftTerm.Color {
        func component(_ shift: UInt32) -> UInt16 {
            UInt16((hex >> shift) & 0xFF) &* 257
        }
        return SwiftTerm.Color(
            red: component(16),
            green: component(8),
            blue: component(0)
        )
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.send = send
        let allowsPrompts = ClaudePromptGate.allows(agent: agent, beacon: beacon)
        if prompts.beacon != beacon || prompts.allowsPrompts != allowsPrompts {
            prompts.beacon = beacon
            prompts.allowsPrompts = allowsPrompts
            DispatchQueue.main.async { [prompts] in prompts.refresh() }
        }
    }

    static func dismantleUIView(_ scroll: UIScrollView, coordinator: Coordinator) {
        if let id = coordinator.frameHandlerID {
            coordinator.connection.removePaneFrameHandler(for: coordinator.paneID, id: id)
        }
        if let id = coordinator.scrollbackHandlerID {
            coordinator.connection.removePaneScrollbackHandler(
                for: coordinator.paneID,
                id: id
            )
        }
        coordinator.search.terminal = nil
        coordinator.prompts.readGrid = nil
    }

    /// History text uses bare `\n`; the emulator needs `\r\n` or every line
    /// inherits the previous line's indent.
    private static func normalizedHistory(_ data: Data) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(data.count + data.count / 16)
        var previous: UInt8 = 0
        for byte in data {
            if byte == 0x0A, previous != 0x0D {
                bytes.append(0x0D)
            }
            bytes.append(byte)
            previous = byte
        }
        return bytes
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        let paneID: String
        let connection: BridgeConnection
        var send: ([UInt8]) -> Void
        var frameHandlerID: UUID?
        var scrollbackHandlerID: UUID?
        weak var terminal: TerminalView?
        let search: TerminalSearchController
        let prompts: TerminalPromptController
        var widthFloor: NSLayoutConstraint?
        var baseWidthFloor: CGFloat = 0
        var charWidth: CGFloat = 0

        /// Widen the view's width floor when the streamed grid outgrows the
        /// 80-column base, so the outer scroll view can pan to every column.
        /// Sized from SwiftTerm's OWN cell metrics (getOptimalFrameSize):
        /// a parallel NSString measurement drifts a fraction of a point per
        /// cell, which across a wide grid leaves the view narrower than the
        /// terminal's content — the terminal then scrolls horizontally inside
        /// the outer pan and every follow-update snaps it back to column 0.
        func updateWidthFloor(cols: Int) {
            guard let widthFloor else { return }
            let gridWidth = terminal.map { ceil($0.getOptimalFrameSize().width) + 4 }
            let fallback = charWidth > 0 ? ceil(charWidth * CGFloat(cols)) + 4 : 0
            let needed = max(baseWidthFloor, gridWidth ?? fallback)
            if abs(widthFloor.constant - needed) > 0.5 {
                widthFloor.constant = needed
            }
        }

        init(
            paneID: String,
            connection: BridgeConnection,
            search: TerminalSearchController,
            prompts: TerminalPromptController,
            send: @escaping ([UInt8]) -> Void
        ) {
            self.paneID = paneID
            self.connection = connection
            self.search = search
            self.prompts = prompts
            self.send = send
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            send(Array(data))
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            // `columns` is a floor: portrait keeps the faithful 80-col grid
            // (scrolling horizontally), landscape stretches the view, so the
            // pty grows with it and the agent TUI reflows edge-to-edge.
            // SwiftTerm fires this on the main thread, but it is a nonisolated
            // protocol method, so hop onto the main actor to touch the connection.
            Task { @MainActor [connection, paneID] in
                connection.resizePane(
                    paneID: paneID,
                    cols: max(StreamingTerminalView.columns, newCols),
                    rows: newRows
                )
            }
        }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

/// Reads the bottom `rows` rendered grid lines straight from SwiftTerm's
/// active buffer. This deliberately ignores the user's scrollback viewport:
/// historical prompts must never become live native actions.
///
/// The terminal comes from `getTerminal()`, never from a delegate callback.
/// An earlier version captured it in `bufferActivated`/`linefeed`, and for an
/// agent pane neither ever fires: herdr's observe stream paints every cell by
/// cursor address without a single line feed or alt-screen switch, and the
/// scrollback seed is empty because herdr's `recent` read of an alt-screen
/// TUI is just the viewport the bridge drops. The grid then read as "" and
/// prompt buttons never appeared.
final class GridReadableTerminalView: TerminalView {
    func liveGridText() -> String {
        let terminal = getTerminal()
        guard let text = String(data: terminal.getBufferAsData(), encoding: .utf8)
        else { return "" }

        var lines = text.components(separatedBy: "\n")
        if lines.last == "" {
            lines.removeLast()
        }
        return lines.suffix(terminal.rows).joined(separator: "\n")
    }
}

enum ClaudePromptGate {
    static func allows(agent: String?, beacon: AgentBeacon?) -> Bool {
        agent?.caseInsensitiveCompare("claude") == .orderedSame || beacon != nil
    }
}

@MainActor
final class TerminalPromptController: ObservableObject {
    private struct UnconfirmedToggle {
        let toggle: PromptPendingToggle
        let sentFrameRevision: UInt64
    }

    @Published private(set) var prompt: PromptModel?
    @Published private(set) var isBusy = false
    @Published private(set) var focusComposerRequest = 0
    var readGrid: (() -> String)?
    var beacon: AgentBeacon?
    var allowsPrompts = true
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private var dismissedIdentity: PromptActionIdentity?
    private var observedDialogSignature: String?
    private var promptInstanceCounter: UInt64 = 0
    private var streamGeneration: UInt64 = 0
    private var gridFrameRevision: UInt64 = 0
    private var choreography: PromptChoreography?
    private var choreographyGeneration = 0
    private var pendingSendKey: ((String) -> Void)?
    private var focusComposerAfterCompletion = false
    private var activeToggleSentFrameRevision: UInt64?
    private var unconfirmedToggle: UnconfirmedToggle?

    func refresh(frameArrived: Bool = false) {
        if frameArrived { gridFrameRevision &+= 1 }
        guard allowsPrompts, let grid = readGrid?() else {
            observedDialogSignature = nil
            prompt = nil
            cancelChoreography()
            unconfirmedToggle = nil
            return
        }
        let detected = trackedPrompt(in: grid)
        if choreography != nil {
            drive(with: detected)
        }
        reconcileUnconfirmedToggle(with: detected)
        if detected?.actionIdentity != dismissedIdentity {
            dismissedIdentity = nil
        }
        prompt = detected?.actionIdentity == dismissedIdentity ? nil : detected
    }

    func invalidateForFullFrame() {
        streamGeneration &+= 1
        observedDialogSignature = nil
        dismissedIdentity = nil
        prompt = nil
        cancelChoreography()
        unconfirmedToggle = nil
    }

    func dismiss(renderedPrompt: PromptModel) {
        guard prompt?.actionIdentity == renderedPrompt.actionIdentity else {
            refresh()
            return
        }
        dismissedIdentity = renderedPrompt.actionIdentity
        prompt = nil
        cancelChoreography()
        unconfirmedToggle = nil
    }

    /// Keep the original numbered permission path as one guarded digit key.
    func sendLegacy(
        renderedPrompt: PromptModel,
        option: PromptOption,
        through send: ([UInt8]) -> Void
    ) {
        guard renderedPrompt.kind == .numberedPermission,
              unconfirmedToggle == nil,
              let digit = option.digit,
              renderedPrompt.options.contains(where: {
                  $0.digit == digit && $0.label == option.label
              }),
              prompt?.actionIdentity == renderedPrompt.actionIdentity,
              let grid = readGrid?(),
              let current = trackedPrompt(in: grid),
              current.actionIdentity == renderedPrompt.actionIdentity,
              current.options.contains(where: {
                  $0.digit == digit && $0.label == option.label
              })
        else {
            refresh()
            return
        }
        send(Array(String(digit).utf8))
        dismiss(renderedPrompt: renderedPrompt)
    }

    func select(
        renderedPrompt: PromptModel,
        option: PromptOption,
        through sendKey: @escaping (String) -> Void
    ) {
        let action: PromptChoreography.Action = renderedPrompt.multiSelect
            && !option.isFreeText && !option.isChat
            ? .toggle(optionID: option.id)
            : .choose(optionID: option.id)
        if case .toggle = action,
           handleToggleRetry(renderedPrompt: renderedPrompt, option: option) {
            return
        }
        begin(
            action,
            renderedPrompt: renderedPrompt,
            focusComposer: option.isFreeText,
            through: sendKey
        )
    }

    func advance(
        renderedPrompt: PromptModel,
        through sendKey: @escaping (String) -> Void
    ) {
        begin(.advance, renderedPrompt: renderedPrompt, through: sendKey)
    }

    func retreat(
        renderedPrompt: PromptModel,
        through sendKey: @escaping (String) -> Void
    ) {
        begin(.retreat, renderedPrompt: renderedPrompt, through: sendKey)
    }

    func submit(
        renderedPrompt: PromptModel,
        through sendKey: @escaping (String) -> Void
    ) {
        begin(.submit, renderedPrompt: renderedPrompt, through: sendKey)
    }

    func sendEscape(renderedPrompt: PromptModel, through send: ([UInt8]) -> Void) {
        guard unconfirmedToggle == nil,
              prompt?.actionIdentity == renderedPrompt.actionIdentity,
              let grid = readGrid?(),
              let current = trackedPrompt(in: grid),
              current.actionIdentity == renderedPrompt.actionIdentity
        else {
            refresh()
            return
        }
        send([0x1B])
        dismiss(renderedPrompt: renderedPrompt)
    }

    private func begin(
        _ action: PromptChoreography.Action,
        renderedPrompt: PromptModel,
        focusComposer: Bool = false,
        through sendKey: @escaping (String) -> Void
    ) {
        guard choreography == nil,
              unconfirmedToggle == nil,
              prompt?.actionIdentity == renderedPrompt.actionIdentity,
              let grid = readGrid?(),
              let current = trackedPrompt(in: grid),
              current.actionIdentity == renderedPrompt.actionIdentity
        else {
            refresh()
            return
        }
        choreography = PromptChoreography(
            action: action,
            prompt: current,
            now: now()
        )
        activeToggleSentFrameRevision = nil
        choreographyGeneration += 1
        let generation = choreographyGeneration
        pendingSendKey = sendKey
        focusComposerAfterCompletion = focusComposer
        isBusy = true
        drive(with: current)
        let deadline = PromptChoreography.responseWindow
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
            guard let self,
                  self.choreography != nil,
                  self.choreographyGeneration == generation
            else { return }
            let current: PromptModel?
            if let grid = self.readGrid?() {
                current = self.trackedPrompt(in: grid)
            } else {
                current = nil
            }
            self.drive(with: current)
        }
    }

    private func drive(with current: PromptModel?) {
        guard var choreography else { return }
        let currentTime = now()
        let pendingToggle = choreography.pendingToggle
        let didExpire = choreography.isExpired(at: currentTime)
        let result = choreography.next(
            prompt: current,
            now: currentTime
        )
        self.choreography = choreography
        switch result {
        case let .sendKey(key):
            if key == "Space", choreography.pendingToggle != nil {
                activeToggleSentFrameRevision = gridFrameRevision
            }
            pendingSendKey?(key)
        case .wait:
            break
        case .complete:
            unconfirmedToggle = nil
            let shouldFocus = focusComposerAfterCompletion
            cancelChoreography()
            if shouldFocus { focusComposerRequest += 1 }
        case .refused:
            if didExpire, let pendingToggle {
                unconfirmedToggle = UnconfirmedToggle(
                    toggle: pendingToggle,
                    sentFrameRevision: activeToggleSentFrameRevision ?? gridFrameRevision
                )
            }
            cancelChoreography()
        }
    }

    private func cancelChoreography() {
        choreography = nil
        pendingSendKey = nil
        focusComposerAfterCompletion = false
        activeToggleSentFrameRevision = nil
        isBusy = false
    }

    private func trackedPrompt(in grid: String) -> PromptModel? {
        guard let detected = PromptDetector.detect(in: grid, beacon: beacon) else {
            observedDialogSignature = nil
            return nil
        }
        let isSameDialog = observedDialogSignature == detected.dialogSignature
        observedDialogSignature = detected.dialogSignature
        if case let .request(requestID, _) = detected.instanceKey {
            return detected.withInstanceKey(
                .request(requestID, streamGeneration: streamGeneration)
            )
        }
        if !isSameDialog { promptInstanceCounter &+= 1 }
        return detected.withInstanceKey(.observed(promptInstanceCounter))
    }

    private func reconcileUnconfirmedToggle(with current: PromptModel?) {
        guard let pending = unconfirmedToggle?.toggle else { return }
        guard let current,
              current.dialogSignature == pending.dialogSignature,
              current.instanceKey == pending.instanceKey,
              current.currentQuestionIndex == pending.questionIndex,
              let option = current.options.first(where: { $0.id == pending.optionID })
        else {
            unconfirmedToggle = nil
            return
        }
        if option.isChecked == pending.wanted { unconfirmedToggle = nil }
    }

    private func handleToggleRetry(
        renderedPrompt: PromptModel,
        option: PromptOption
    ) -> Bool {
        guard let pendingState = unconfirmedToggle else { return false }
        let pending = pendingState.toggle
        guard pending.optionID == option.id,
              pending.dialogSignature == renderedPrompt.dialogSignature,
              pending.instanceKey == renderedPrompt.instanceKey,
              pending.questionIndex == renderedPrompt.currentQuestionIndex,
              let grid = readGrid?(),
              let current = trackedPrompt(in: grid),
              let liveOption = current.options.first(where: { $0.id == pending.optionID })
        else {
            refresh()
            return true
        }
        if liveOption.isChecked == pending.wanted {
            unconfirmedToggle = nil
            prompt = current
            return true
        }
        guard gridFrameRevision > pendingState.sentFrameRevision else {
            return true
        }
        guard current.actionIdentity == renderedPrompt.actionIdentity else {
            refresh()
            return true
        }
        unconfirmedToggle = nil
        return false
    }
}

private struct PromptBar: View {
    let prompt: PromptModel
    let isBusy: Bool
    let select: (PromptOption) -> Void
    let advance: () -> Void
    let retreat: () -> Void
    let submit: () -> Void
    let escape: () -> Void
    let dismiss: () -> Void

    @ViewBuilder
    var body: some View {
        if prompt.kind == .numberedPermission {
            legacyBar
        } else {
            structuredBar
        }
    }

    private var legacyBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(prompt.options) { option in
                    Button {
                        select(option)
                    } label: {
                        HStack(spacing: 4) {
                            Text(option.digit.map(String.init) ?? "")
                                .font(.caption.monospacedDigit().weight(.bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.secondary.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                            Text(option.label)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button("Esc", action: escape)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss prompt controls")
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }

    private var structuredBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !prompt.steps.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(prompt.steps) { step in
                            Label(step.label, systemImage: stepSymbol(step.state))
                                .font(.caption.weight(step.state == .current ? .bold : .regular))
                                .foregroundStyle(step.state == .current ? .primary : .secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    step.state == .current
                                        ? Color.accentColor.opacity(0.18)
                                        : Color.secondary.opacity(0.08),
                                    in: Capsule()
                                )
                        }
                    }
                }
            }
            if let question = prompt.question {
                Text(question)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if prompt.submitState == .none {
                if prompt.isFreeTextEntryActive {
                    Label("Enter your answer in the composer", systemImage: "keyboard")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(prompt.options) { option in
                                optionCard(option)
                            }
                        }
                    }
                    .frame(maxHeight: 230)
                }
            } else {
                submitControls
            }
            HStack {
                if prompt.showsPreviousAction {
                    Button("Previous", action: retreat)
                        .buttonStyle(.bordered)
                        .disabled(isBusy)
                }
                if prompt.multiSelect, !prompt.isFreeTextEntryActive {
                    Button("Next", action: advance)
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            isBusy
                                || prompt.currentQuestionIndex == nil
                                || !prompt.options.contains(where: { $0.isChecked == true })
                        )
                }
                Spacer()
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Checking terminal response")
                }
                Button("Esc", action: escape)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isBusy)
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(isBusy)
                .accessibilityLabel("Dismiss prompt controls")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func optionCard(_ option: PromptOption) -> some View {
        Button { select(option) } label: {
            HStack(alignment: .top, spacing: 9) {
                if prompt.multiSelect, !option.isFreeText, !option.isChat {
                    Image(systemName: option.isChecked == true ? "checkmark.square.fill" : "square")
                        .foregroundStyle(option.isChecked == true ? Color.accentColor : .secondary)
                } else if option.isSelected {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.subheadline.weight(.medium))
                        .multilineTextAlignment(.leading)
                    if let description = option.description {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 4)
                if option.isFreeText {
                    Image(systemName: "keyboard")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(9)
            .background(
                option.isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(option.isSelected ? Color.accentColor.opacity(0.45) : .clear)
            }
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }

    private var submitControls: some View {
        HStack(spacing: 8) {
            Button("Submit", action: submit)
                .buttonStyle(.borderedProminent)
                .disabled(isBusy || prompt.submitState != .ready)
            if let cancel = prompt.options.first(where: {
                $0.label.localizedCaseInsensitiveContains("cancel")
            }) {
                Button("Cancel") { select(cancel) }
                    .buttonStyle(.bordered)
                    .disabled(isBusy)
            }
            if prompt.submitState == .unavailable {
                Text("Answer every question first")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func stepSymbol(_ state: PromptStepState) -> String {
        switch state {
        case .done: "checkmark.circle.fill"
        case .current: "circle.inset.filled"
        case .pending: "circle"
        }
    }
}

@MainActor
private final class TerminalSearchController: ObservableObject {
    @Published private(set) var summary = "0/0"
    /// Tracks the system keyboard globally (terminal-direct or compose bar) so
    /// the toolbar button can flip between summon and dismiss.
    @Published private(set) var keyboardVisible = false
    weak var terminal: TerminalView?
    private var keyboardObservers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        keyboardObservers = [
            center.addObserver(
                forName: UIResponder.keyboardWillShowNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.keyboardVisible = true }
            },
            center.addObserver(
                forName: UIResponder.keyboardWillHideNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.keyboardVisible = false }
            },
        ]
    }

    deinit {
        for observer in keyboardObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Raise the system keyboard in direct mode: keystrokes go straight to the
    /// pty (SwiftTerm is the first responder), not the compose bar.
    func focusKeyboard() {
        _ = terminal?.becomeFirstResponder()
    }

    func toggleKeyboard() {
        if keyboardVisible {
            // Ask the window to end editing: it resigns whichever field owns
            // the keyboard — the terminal or the compose bar. Dispatching
            // resignFirstResponder through UIApplication.sendAction does NOT
            // work here: SwiftTerm's canPerformAction whitelist rejects the
            // selector, so UIKit walks past the terminal and "resigns" an
            // ancestor that never held the keyboard.
            terminal?.window?.endEditing(true)
        } else {
            focusKeyboard()
        }
    }

    func search(_ query: String) {
        terminal?.clearSearch()
        if query.isEmpty {
            summary = "0/0"
        } else {
            next(query)
        }
    }

    func next(_ query: String) {
        guard !query.isEmpty else { return }
        _ = terminal?.findNext(query)
        updateSummary(query)
    }

    func previous(_ query: String) {
        guard !query.isEmpty else { return }
        _ = terminal?.findPrevious(query)
        updateSummary(query)
    }

    func clear() {
        terminal?.clearSearch()
        summary = "0/0"
    }

    private func updateSummary(_ query: String) {
        let value: (index: Int, total: Int) =
            terminal?.searchMatchSummary(query) ?? (index: 0, total: 0)
        summary = "\(value.index)/\(value.total)"
    }
}

private enum PhotoSendError: LocalizedError {
    case invalidImage

    var errorDescription: String? {
        "The selected image could not be prepared under the 5 MB limit."
    }
}

private extension UIImage {
    func resized(by scale: CGFloat) -> UIImage {
        let size = CGSize(
            width: max(1, self.size.width * scale),
            height: max(1, self.size.height * scale)
        )
        return UIGraphicsImageRenderer(size: size).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

private struct TerminalControlToolbar: View {
    let send: ([UInt8]) -> Void

    private let controls: [(String, [UInt8])] = [
        ("Return", [0x0D]),
        ("Esc", [0x1B]),
        ("Tab", [0x09]),
        ("Ctrl-C", [0x03]),
        ("↑", [0x1B, 0x5B, 0x41]),
        ("↓", [0x1B, 0x5B, 0x42]),
        ("←", [0x1B, 0x5B, 0x44]),
        ("→", [0x1B, 0x5B, 0x43]),
        ("Ctrl-R", [0x12]),
        ("Ctrl-D", [0x04]),
        ("Ctrl-Z", [0x1A]),
        ("Ctrl-L", [0x0C]),
        ("Shift-Tab", [0x1B, 0x5B, 0x5A]),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(controls, id: \.0) { label, bytes in
                    Button(label) { send(bytes) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        // Key chips, not actions: in accent blue the ↑ chip
                        // reads as a second Send button. Neutral gray keeps
                        // Send as the compose bar's only prominent action.
                        .tint(.gray)
                        .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }
}
