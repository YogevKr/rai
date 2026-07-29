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
        VStack(spacing: 0) {
            StreamingTerminalView(
                paneID: pane.paneID,
                connection: connection,
                search: terminalSearch,
                prompts: promptController,
                send: { connection.sendInput($0, to: pane.paneID) }
            )
            // Breathing room between the last terminal row and the compose
            // bar / keyboard stack; padding sits inside the background so the
            // gap stays terminal-colored.
            .padding(.bottom, 2)
            .background(Color(red: 33 / 255, green: 33 / 255, blue: 33 / 255))

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

            if let prompt = promptController.prompt {
                PromptBar(
                    prompt: prompt,
                    select: { option in
                        promptController.send(
                            option: option,
                            // Dialogs listen for keypresses; a digit sent as
                            // text arrives as a paste and is ignored. Route
                            // the answer through herdr's key semantics.
                            through: { bytes in
                                connection.sendKeys(
                                    [String(decoding: bytes, as: UTF8.self)],
                                    to: pane.paneID
                                )
                            }
                        )
                    },
                    escape: {
                        promptController.sendEscape(
                            through: { connection.sendInput($0, to: pane.paneID) }
                        )
                    },
                    dismiss: promptController.dismiss
                )
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
                        Image(systemName: "slash.circle")
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
                // While the field is focused the keyboard's blue ↑ IS the
                // send button — showing a second one beside it reads as a
                // double send. The button appears when it's the only way to
                // send (keyboard away, drafted text) or as the red "Sure?"
                // destructive confirmation.
                if destructiveArmed || (!composeFocused && !composedLine.isEmpty) {
                    Button(destructiveArmed ? "Sure?" : "Send", action: sendComposedLine)
                        .buttonStyle(.borderedProminent)
                        .tint(destructiveArmed ? .red : nil)
                }
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
            // A plain terminal pane (no detected agent) is for typing: put the
            // keyboard straight into the pty. Agent panes keep the calmer
            // compose-bar default — the toolbar keyboard button opts in.
            if pane.agent == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    terminalSearch.focusKeyboard()
                }
            }
        }
        .onDisappear { connection.detachPane(paneID: pane.paneID) }
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
        sendLine(text)
        composedLine = ""
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
                terminal?.feed(byteArray: [0x1B, 0x5B, 0x48, 0x1B, 0x5B, 0x32, 0x4A][...])
            }
            terminal?.feed(byteArray: [UInt8](data)[...])
            context.coordinator.prompts.refresh()
            if full {
                // A stream (re)start means "show me the live screen": park the
                // viewport at the bottom, above the seeded scrollback. Async so
                // the feed's layout/contentSize update lands first.
                DispatchQueue.main.async { [weak terminal] in
                    guard let terminal else { return }
                    let bottom = max(0, terminal.contentSize.height - terminal.bounds.height)
                    terminal.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
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

/// Captures SwiftTerm's active buffer object through its delegate callbacks,
/// then reads the bottom `rows` rendered grid lines. This deliberately ignores
/// the user's scrollback viewport: historical prompts must never become live
/// native actions.
private final class GridReadableTerminalView: TerminalView {
    private weak var gridTerminal: SwiftTerm.Terminal?

    override func bufferActivated(source: SwiftTerm.Terminal) {
        gridTerminal = source
        super.bufferActivated(source: source)
    }

    override func linefeed(source: SwiftTerm.Terminal) {
        gridTerminal = source
        super.linefeed(source: source)
    }

    func liveGridText() -> String {
        guard let terminal = gridTerminal,
              let text = String(data: terminal.getBufferAsData(), encoding: .utf8)
        else { return "" }

        var lines = text.components(separatedBy: "\n")
        if lines.last == "" {
            lines.removeLast()
        }
        return lines.suffix(terminal.rows).joined(separator: "\n")
    }
}

@MainActor
private final class TerminalPromptController: ObservableObject {
    @Published private(set) var prompt: PromptModel?
    var readGrid: (() -> String)?
    private var dismissedSignature: String?

    func refresh() {
        guard let grid = readGrid?() else {
            prompt = nil
            return
        }
        let detected = PromptDetector.detect(in: grid)
        if detected?.signature != dismissedSignature {
            dismissedSignature = nil
        }
        prompt = detected?.signature == dismissedSignature ? nil : detected
    }

    func dismiss() {
        dismissedSignature = prompt?.signature
        prompt = nil
    }

    func send(option: PromptOption, through send: ([UInt8]) -> Void) {
        guard let current = prompt,
              let grid = readGrid?(),
              PromptDetector.signatureMatches(current, currentGridText: grid)
        else {
            refresh()
            return
        }
        send(Array(String(option.digit).utf8))
        dismiss()
    }

    func sendEscape(through send: ([UInt8]) -> Void) {
        guard let current = prompt,
              let grid = readGrid?(),
              PromptDetector.signatureMatches(current, currentGridText: grid)
        else {
            refresh()
            return
        }
        send([0x1B])
        dismiss()
    }
}

private struct PromptBar: View {
    let prompt: PromptModel
    let select: (PromptOption) -> Void
    let escape: () -> Void
    let dismiss: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(prompt.options) { option in
                    Button {
                        select(option)
                    } label: {
                        HStack(spacing: 4) {
                            Text("\(option.digit)")
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
