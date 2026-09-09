import AppKit
import RaiCore
import SwiftUI
import SwiftTerm

private struct EndpointWindowFocusKey: FocusedValueKey {
    typealias Value = EndpointWindowModel
}

extension FocusedValues {
    var endpointWindow: EndpointWindowModel? {
        get { self[EndpointWindowFocusKey.self] }
        set { self[EndpointWindowFocusKey.self] = newValue }
    }
}

struct EndpointWindow: View {
    @StateObject private var model: EndpointWindowModel
    @ObservedObject private var machines = MachineDirectory.shared
    @StateObject private var links = EndpointNativeLinks()
    @StateObject private var clipboard = EndpointClipboard()
    @State private var imageSnapshot: EndpointImageSnapshot?
    @State private var presentation: EndpointPresentationSnapshot?
    @State private var showingMetadata = false
    @State private var showingMachines = false
    @State private var showingLayout = false
    @State private var layoutSnapshot: HerdrEndpointSnapshot?
    @State private var layoutViewID: UUID?
    @State private var showingWorktrees = false
    @State private var worktreeSnapshot: HerdrEndpointSnapshot?
    @State private var launchSnapshot: HerdrEndpointSnapshot?
    @State private var launchViewID = UUID()
    @State private var showingAgentLaunch = false
    @State private var showingPlugins = false
    @State private var showingNotifications = false
    @State private var showingTextTools = false
    @State private var textMode = EndpointTextToolsSheet.Mode.history
    @State private var textSnapshot: HerdrEndpointSnapshot?
    @SceneStorage("endpointAppearance") private var appearance = EndpointAppearance.system
    @SceneStorage("endpointBorders") private var borders = EndpointBorderMode.auto
    @SceneStorage("endpointTheme") private var theme = ""

    private var palette: EndpointThemePalette {
        let dark = appearance.colorScheme.map { $0 == .dark }
            ?? (NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        return EndpointThemePalette(theme: theme, dark: dark)
    }

    init(socketPath: String, remoteContext: RemoteConnection.Context? = nil) {
        _model = StateObject(wrappedValue: EndpointWindowModel(socketPath: socketPath, remoteContext: remoteContext))
        let defaults = UserDefaults.standard
        _appearance = SceneStorage(wrappedValue: EndpointAppearance(
            rawValue: defaults.string(forKey: "endpointAppearance") ?? "") ?? .system, "endpointAppearance")
        _borders = SceneStorage(wrappedValue: EndpointBorderMode(
            rawValue: defaults.string(forKey: "endpointBorders") ?? "") ?? .auto, "endpointBorders")
        _theme = SceneStorage(wrappedValue: defaults.string(forKey: "endpointTheme") ?? "", "endpointTheme")
    }

    var body: some View {
        NavigationSplitView {
            List {
                if let snapshot = model.snapshot {
                    if snapshot.agentViewLabel != nil {
                        EndpointAgentViewRows(snapshot: snapshot, busy: model.busy, select: { model.select(paneID: $0) }, palette: palette)
                    } else {
                    ForEach(snapshot.workspaces.indices, id: \.self) { index in
                        let workspace = snapshot.workspaces[index].objectValue ?? [:]
                        let workspaceID = workspace["workspace_id"]?.stringValue
                        Section {
                            ForEach(snapshot.panes.indices, id: \.self) { paneIndex in
                                let pane = snapshot.panes[paneIndex].objectValue ?? [:]
                                if pane["workspace_id"]?.stringValue == workspaceID,
                                   let paneID = pane["pane_id"]?.stringValue {
                                    Button { model.select(paneID: paneID) } label: {
                                        HStack {
                                            VStack(alignment: .leading) {
                                                if let agent = snapshot.agents.first(where: { $0.objectValue?["pane_id"]?.stringValue == paneID }) {
                                                    EndpointMetadataRows(record: agent, kind: .agent, snapshot: snapshot, foreground: palette.foreground)
                                                } else {
                                                    Text(pane["label"]?.stringValue ?? URL(fileURLWithPath:
                                                        pane["foreground_cwd"]?.stringValue ?? pane["cwd"]?.stringValue ?? "/").lastPathComponent)
                                                }
                                                Text(paneID).font(.caption).foregroundStyle(palette.secondary)
                                            }
                                            Spacer()
                                            if snapshot.focusedPaneID == paneID { Image(systemName: "checkmark") }
                                        }
                                    }
                                    .foregroundStyle(palette.foreground)
                                    .listRowBackground(snapshot.focusedPaneID == paneID
                                        ? palette.color("active_row_bg", fallback: .clear) : palette.sidebar)
                                    .accessibilityIdentifier("endpoint-pane-\(paneID)")
                                    .disabled(model.busy)
                                }
                            }
                        } header: {
                            EndpointMetadataRows(record: snapshot.workspaces[index], kind: .workspace, snapshot: snapshot, foreground: palette.foreground)
                        }
                    }
                    }
                }
            }
            .scrollContentBackground(theme.isEmpty ? .visible : .hidden)
            .background(palette.sidebar)
            .tint(palette.color("accent", fallback: .accentColor))
            .navigationSplitViewColumnWidth(min: 180, ideal: 240)
        } detail: {
            VStack(spacing: 0) {
                if let snapshot = model.snapshot, !snapshot.tabBarRight.isEmpty { EndpointTabStatus(snapshot: snapshot).padding(4) }
                if let warning = model.graphicsPolicyWarning { Text(warning).font(.caption).padding(4) }
                if let popup = model.surface?.popup { Text(popup.title).font(.headline).padding(6) }
                if let error = model.error {
                    HStack {
                        Text(error).textSelection(.enabled)
                        Button("Reconnect") { model.reconnect() }
                    }.padding()
                }
                EndpointTerminal(model: model, theme: theme, links: links, clipboard: clipboard)
                    .overlay { EndpointPaneBorders(surface: model.surface, mode: borders) }
                    .overlay { EndpointScrollOverlay(surface: model.surface, activity: model.scrollActivity) }
                    .overlay(alignment: .bottom) { EndpointClipboardNotice(clipboard: clipboard) }
            }
        }
        .toolbar {
            Button("Machines") {
                showingMachines = true
                Task { await machines.perform(.init(revision: machines.state.revision, operation: .refresh)) }
            }
            EndpointAppearanceMenu(appearance: $appearance, borders: $borders, theme: $theme)
            Button("Metadata") { showingMetadata = true }.disabled(model.snapshot == nil)
            Button("Start Agent") { launchViewID = model.generation; launchSnapshot = model.snapshot; showingAgentLaunch = true }
                            .disabled(model.busy || model.snapshot?.focusedPaneID == nil)
                        Button("Plugins") { showingPlugins = true }.disabled(model.snapshot == nil)
            Button("Notifications") { showingNotifications = true }
            Button("Layout") {
                layoutSnapshot = model.snapshot; layoutViewID = model.generation; showingLayout = true
            }.disabled(model.snapshot == nil)

            Menu("Text") {
                Button("History and Search") {
                    textSnapshot = model.snapshot; textMode = .history; showingTextTools = true
                }.disabled(!model.methods.contains("pane.selection.read"))
                Button("Agent Prompt") {
                    textSnapshot = model.snapshot; textMode = .prompt; showingTextTools = true
                }.disabled(model.snapshot?.agents.contains(where: {
                    $0.objectValue?["pane_id"]?.stringValue == model.snapshot?.focusedPaneID
                }) != true)
            }.disabled(model.snapshot == nil)
            Button("Worktrees") {
                worktreeSnapshot = model.snapshot
                showingWorktrees = true
            }.disabled(model.snapshot == nil || !model.methods.contains("worktree.list"))
            Button("Commands") {
                if let snapshot = model.snapshot { presentation = .init(snapshot: snapshot, page: .commands) }
            }.disabled(model.busy || !model.methods.contains("command.invoke"))
            Button("News") {
                if let snapshot = model.snapshot { presentation = .init(snapshot: snapshot, page: .news) }
            }.disabled(model.snapshot == nil)
            Button("Images") { imageSnapshot = EndpointImageSnapshot(scene: model.surface?.graphics) }
                .disabled(model.surface?.graphics.placements.isEmpty != false)
        }
        .sheet(item: $imageSnapshot) { EndpointImagesSheet(scene: $0.scene) }
        .sheet(item: $presentation) { EndpointPresentationSheet(captured: $0, invoke: model.invoke) }
        .sheet(isPresented: $showingMetadata) {
            if let snapshot = model.snapshot { EndpointMetadataSettings(snapshot: snapshot) }
        }
        .sheet(isPresented: $showingMachines) {
            MachinePickerSheet(state: machines.state, select: { model.selectMachine($0) },
                               openAgent: { model.selectAgent($0) }, perform: { operation in
                Task { await machines.perform(.init(revision: machines.state.revision, operation: operation)) }
            })
        }
        .sheet(isPresented: $showingLayout) {
            if let snapshot = layoutSnapshot, let viewID = layoutViewID {
                EndpointLayoutSheet(snapshot: snapshot, owningViewID: viewID, currentViewID: model.generation,
                    currentBootID: model.snapshot?.bootID, result: model.layoutResult, busy: model.busy,
                    methods: model.methods, submit: { model.performLayout($0) })
            }
        }
        .sheet(isPresented: $showingWorktrees) {
            if let snapshot = worktreeSnapshot {
                EndpointWorktreesSheet(snapshot: snapshot, currentBootID: model.snapshot?.bootID,
                    result: model.worktreeResult, busy: model.busy, methods: model.methods, submit: model.performWorktree)
            }
        }
        .sheet(isPresented: $showingAgentLaunch) {
                if let snapshot = launchSnapshot {
                    EndpointAgentLaunchSheet(snapshot: snapshot, currentBootID: model.snapshot?.bootID,
                        owningViewID: launchViewID, currentViewID: model.generation,
                        result: model.agentLaunchResult, busy: model.busy, submit: { model.launchAgent($0) })
                }
            }
            .sheet(isPresented: $showingPlugins) {
            if let snapshot = model.snapshot {
                EndpointPluginSheet(snapshot: snapshot, surface: model.surface, result: model.pluginResult,
                    busy: model.busy, methods: model.methods, submit: model.performPlugin)
            }
        }
        .sheet(isPresented: $showingNotifications) { EndpointNotificationSettings(notifications: model.notifications) }
        .sheet(isPresented: $showingTextTools) {
            if let snapshot = textSnapshot {
                EndpointTextToolsSheet(mode: textMode, snapshot: snapshot, surface: model.surface,
                    currentBootID: model.snapshot?.bootID, result: model.terminalResult, busy: model.busy,
                    submit: model.performTerminalAction)
            }
        }
        .modifier(EndpointNotificationPresentation(notifications: model.notifications))
        .navigationTitle(model.windowTitle ?? "Workspace")
        .modifier(EndpointLinkPresentation(links: links, result: model.pluginResult, surface: model.surface))
        .onChange(of: model.generation) { _, _ in links.reset() }
        .frame(minWidth: 760, minHeight: 480)
        .modifier(EndpointMacAppearance(appearance: appearance))
        .onChange(of: appearance) { _, value in UserDefaults.standard.set(value.rawValue, forKey: "endpointAppearance") }
        .onChange(of: borders) { _, value in UserDefaults.standard.set(value.rawValue, forKey: "endpointBorders") }
        .onChange(of: theme) { _, value in UserDefaults.standard.set(value, forKey: "endpointTheme") }
        .focusedSceneValue(\.endpointWindow, model)
        .task { model.start() }
        .onDisappear { model.stop() }
    }
}

final class EndpointTerminalView: EndpointMouseTerminalView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        optionAsMetaKey = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        optionAsMetaKey = false
    }

    var pasteText: ((String) -> Void)?
    var semanticKey: ((EndpointKey) -> Void)?
    var scrollRemote: ((String, UInt64) -> Void)?
    private var scrollTarget: (paneID: String, offset: UInt64)?
    private var lastScrollTime = TimeInterval.zero
    private var scrollFraction: CGFloat = 0

    func handleInterceptedScroll(_ event: NSEvent) {
        if sendMouseWheel(event) { return }
        guard let surface = endpointSurface, event.scrollingDeltaY != 0 else { return }
        let frame = getOptimalFrameSize()
        let cellWidth = frame.width / CGFloat(max(1, surface.grid.width))
        let cellHeight = frame.height / CGFloat(max(1, surface.grid.height))
        let point = convert(event.locationInWindow, from: nil)
        let row = (isFlipped ? point.y : bounds.height - point.y) / cellHeight
        let column = point.x / cellWidth
        guard let pane = surface.panes.first(where: {
            column >= CGFloat($0.innerRect.x) && column < CGFloat($0.innerRect.x) + CGFloat($0.innerRect.width)
                && row >= CGFloat($0.innerRect.y) && row < CGFloat($0.innerRect.y) + CGFloat($0.innerRect.height)
        }), let metrics = pane.scroll else { return }
        if scrollTarget?.paneID != pane.paneID || event.timestamp - lastScrollTime > 0.7 {
            scrollTarget = (pane.paneID, metrics.offset)
            scrollFraction = 0
        }
        lastScrollTime = event.timestamp
        scrollFraction += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / cellHeight : event.scrollingDeltaY * 3
        let lines = Int(scrollFraction)
        scrollFraction -= CGFloat(lines)
        guard lines != 0 else { return }
        let offset = EndpointScroll.offset(from: scrollTarget?.offset ?? metrics.offset, lines: lines, maximum: metrics.maximum)
        scrollTarget = (pane.paneID, offset)
        scrollRemote?(pane.paneID, offset)
    }


    func handleInterceptedKey(_ event: NSEvent) -> Bool {
        guard !hasMarkedText(), !event.modifierFlags.contains(.command) else { return false }
        if let key = EndpointKeyboard.key(for: event) {
            semanticKey?(key)
            return true
        }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .function])
        if modifiers.isEmpty, let text = event.characters,
           text.unicodeScalars.allSatisfy({ $0.value >= 32 && !(127...159).contains($0.value) }),
           text.unicodeScalars.contains(where: { $0.value > 127 }) {
            send(txt: text)
            return true
        }
        return false
    }

    override func paste(_ sender: Any) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        pasteText?(text)
    }

    var clipboard = EndpointClipboard()

    override func copy(_ sender: Any) {
        guard let selected = getSelection(), !selected.isEmpty else { return }
        clipboard.copy(selected)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        // AppKit can commit styled text. SwiftTerm accepts only a plain string here.
        super.insertText((string as? NSAttributedString)?.string ?? string, replacementRange: replacementRange)
    }
}

private struct EndpointTerminal: NSViewRepresentable {
    @ObservedObject var model: EndpointWindowModel
    let theme: String
    let links: EndpointNativeLinks
    let clipboard: EndpointClipboard
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator(model: model, links: links) }

    func makeNSView(context: Context) -> TerminalView {
        let view = EndpointTerminalView(frame: .zero)
        view.clipboard = clipboard
        view.allowMouseReporting = false
        view.observeMouseSurface(model.$surface)
        TerminalScrollIndicator.hideBuiltIn(in: view)
        // The endpoint owns history. Local resize must not retain old screen rows.
        view.getTerminal().changeScrollback(nil)
        view.pasteText = { [weak model] text in model?.send(text, paste: true) }
        view.semanticKey = { [weak model] key in model?.send(.key(key)) }
        view.semanticMouse = { [weak model] target, surface in
            guard let model, model.acceptsInput else { return false }
            model.send(.mouse(target.input), paneID: target.paneID, bootID: surface.bootID,
                       projectionRevision: surface.projectionRevision)
            return model.acceptsInput
        }
        view.scrollRemote = { [weak model] paneID, offset in model?.scroll(paneID: paneID, offset: offset) }
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.terminalDelegate = context.coordinator
        GhosttyTheme.apply(to: view)
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {
        let coordinator = context.coordinator
        let dark = colorScheme == .dark
        let appearanceChanged = coordinator.dark != dark || coordinator.theme != theme
        if appearanceChanged {
            EndpointTerminalAppearance.apply(view, dark: dark, theme: EndpointTheme.stored(theme))
            coordinator.dark = dark
            coordinator.theme = theme
        }
        if coordinator.generation != model.generation {
            coordinator.generation = model.generation
            (view as? EndpointMouseTerminalView)?.endpointSurface = nil
            coordinator.grid = nil
            coordinator.renderKey = nil
            view.feed(text: "\u{1b}[2J\u{1b}[H")
        }
        (view as? EndpointTerminalView)?.endpointSurface = model.surface
        guard let surface = model.surface else { return }
        let renderKey = EndpointSurfaceRenderKey(surface)
        guard appearanceChanged || coordinator.renderKey != renderKey else { return }
        coordinator.painting = true
        defer { coordinator.painting = false }
        view.resize(cols: Int(surface.grid.width), rows: Int(surface.grid.height))
        let grid = surface.presentationGrid
        let bytes = EndpointANSI.render(grid, previous: !appearanceChanged && coordinator.renderKey?.bootID == surface.bootID ? coordinator.grid : nil)
        view.feed(byteArray: Array(bytes)[...])
        // Full text repaint clears SwiftTerm image data, even when geometry stays unchanged.
        let resetGraphics = appearanceChanged || coordinator.renderKey?.bootID != surface.bootID
            || coordinator.grid?.width != grid.width || coordinator.grid?.height != grid.height
        view.feed(byteArray: Array(coordinator.graphics.render(surface.presentationGraphics, grid: grid, reset: resetGraphics))[...])
        coordinator.grid = grid
        coordinator.renderKey = renderKey
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        let model: EndpointWindowModel
        let links: EndpointNativeLinks
        var grid: EndpointGrid?
        var graphics = EndpointGraphicsEncoder()
        var renderKey: EndpointSurfaceRenderKey?
        var generation: UUID?
        var painting = false
        var dark: Bool?
        var theme: String?

        init(model: EndpointWindowModel, links: EndpointNativeLinks) { self.model = model; self.links = links }
        func send(source: TerminalView, data: ArraySlice<UInt8>) { if !painting { model.send(data) } }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            if !painting { model.resize(columns: newCols, rows: newRows) }
        }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let surface = model.surface, let window = source.window else { return }
            let size = source.getOptimalFrameSize(), point = source.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            guard size.width > 0, size.height > 0 else { return }
            let row = (source.isFlipped ? point.y : source.bounds.height - point.y) * CGFloat(surface.grid.height) / size.height
            let column = point.x * CGFloat(surface.grid.width) / size.width
            links.activate(url: link, column: Int(floor(column)), row: Int(floor(row)), surface: surface, submit: model.performPlugin)
        }
    }
}
