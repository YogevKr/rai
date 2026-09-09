import RaiCore
import SwiftUI
import SwiftTerm
import UIKit

struct EndpointPhoneView: View {
    @ObservedObject var connection: BridgeConnection
    @ObservedObject var model: EndpointPhoneModel
    let systemColorScheme: ColorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingPanes = false
    @State private var showingMetadata = false
    @State private var showingTheme = false
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
    @State private var imageSnapshot: EndpointImageSnapshot?
    @State private var presentation: EndpointPresentationSnapshot?
    @AppStorage("endpointAppearance") private var appearance = EndpointAppearance.system
    @AppStorage("endpointBorders") private var borders = EndpointBorderMode.auto
    @AppStorage("endpointTheme") private var theme = ""
    @State private var selectionSnapshot: TerminalTextSnapshot?
    @StateObject private var terminalReference = EndpointPhoneTerminalReference()
    @StateObject private var links = EndpointNativeLinks()
    @StateObject private var clipboard = EndpointClipboard()

    private var palette: EndpointThemePalette {
        EndpointThemePalette(theme: theme, dark: (appearance.colorScheme ?? systemColorScheme) == .dark)
    }

    init(connection: BridgeConnection, systemColorScheme: ColorScheme) {
        self.connection = connection
        self.model = connection.endpointView
        self.systemColorScheme = systemColorScheme
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let snapshot = model.state?.snapshot, !snapshot.tabBarRight.isEmpty { EndpointTabStatus(snapshot: snapshot).padding(4) }
                if let warning = model.state?.graphicsPolicyWarning { Text(warning).font(.caption).padding(4) }
                if let popup = model.state?.surface?.popup { Text(popup.title).font(.headline).padding(6) }
                if let error = model.error {
                    HStack {
                        Text(error).font(.callout)
                        Button("Reconnect") { connection.openEndpointView() }
                    }.padding()
                } else if model.busy { ProgressView("Loading workspace…").padding(4) }
                EndpointPhoneTerminal(model: model, theme: theme, links: links, clipboard: clipboard, reference: terminalReference)
                    .overlay { EndpointPaneBorders(surface: model.state?.surface, mode: borders) }
                    .overlay { EndpointScrollOverlay(surface: model.state?.surface, activity: model.scrollActivity) }
                    .overlay(alignment: .bottom) { EndpointClipboardNotice(clipboard: clipboard) }
                HStack {
                    Button("Esc") { model.input(.special(.escape, modifiers: 0)) }
                    Button("Tab") { model.input(.special(.tab, modifiers: 0)) }
                    Spacer()
                    ForEach([EndpointKey.Special.left, .down, .up, .right], id: \.rawValue) { key in
                        Button { model.input(.special(key, modifiers: 0)) } label: {
                            Image(systemName: arrow(key))
                        }.accessibilityLabel(arrow(key))
                    }
                    Spacer()
                    Button { model.input(.special(.enter, modifiers: 0)) } label: {
                        Image(systemName: "return")
                    }.accessibilityLabel("Return")
                }
                .buttonStyle(.bordered).padding(6).disabled(!model.acceptsInput)
            }
            .navigationTitle(model.state?.windowTitle ?? "Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem { Button("Panes") { showingPanes = true }.disabled(model.state?.snapshot == nil) }
                ToolbarItem {
                    Menu("Actions") {
                        Button("Machines") {
                            showingMachines = true
                            connection.requestMachines()
                        }.disabled(connection.hostCapabilities?.operations.contains(BridgeCapability.machineDirectory) != true)
                        EndpointAppearanceMenu(appearance: $appearance, borders: $borders, theme: $theme,
                            presentTheme: { showingTheme = true })
                        Button("Metadata Layouts") { showingMetadata = true }.disabled(model.state?.snapshot == nil)
                        Button("Start Agent") { launchViewID = model.identity?.viewID ?? UUID(); launchSnapshot = model.state?.snapshot; showingAgentLaunch = true }
                            .disabled(model.busy || model.state?.snapshot?.focusedPaneID == nil)
                        Button("Plugins and Views") { showingPlugins = true }.disabled(model.state?.snapshot == nil)
                        Button("Notifications") { showingNotifications = true }
                        Button("Layout") {
                            layoutSnapshot = model.state?.snapshot; layoutViewID = model.identity?.viewID; showingLayout = true
                        }.disabled(model.state?.snapshot == nil)

                        Button("Worktrees") {
                            worktreeSnapshot = model.state?.snapshot
                            showingWorktrees = true
                        }.disabled(model.state?.methods.contains("worktree.list") != true)
                        Button("Commands") {
                            if let snapshot = model.state?.snapshot { presentation = .init(snapshot: snapshot, page: .commands) }
                        }.disabled(model.busy || model.state?.methods.contains("command.invoke") != true)
                        Button("Herdr News") {
                            if let snapshot = model.state?.snapshot { presentation = .init(snapshot: snapshot, page: .news) }
                        }.disabled(model.state?.snapshot == nil)
                        Button("Select Text") { selectionSnapshot = TerminalTextSnapshot(terminal: terminalReference.terminal) }
                        Button("History and Search") {
                            textSnapshot = model.state?.snapshot; textMode = .history; showingTextTools = true
                        }.disabled(model.state?.methods.contains("pane.selection.read") != true)
                        Button("Agent Prompt") {
                            textSnapshot = model.state?.snapshot; textMode = .prompt; showingTextTools = true
                        }.disabled(model.state?.snapshot?.agents.contains(where: {
                            $0.objectValue?["pane_id"]?.stringValue == model.state?.snapshot?.focusedPaneID
                        }) != true)
                        Button("Inspect Images") { imageSnapshot = EndpointImageSnapshot(scene: model.state?.surface?.graphics) }
                            .disabled(model.state?.surface?.graphics.placements.isEmpty != false)
                        EndpointPhoneActions(model: model)
                    }
                }
            }
            .sheet(item: $selectionSnapshot) { TerminalTextSelectionSheet(snapshot: $0) }
            .sheet(item: $imageSnapshot) { EndpointImagesSheet(scene: $0.scene) }
            .sheet(item: $presentation) { EndpointPresentationSheet(captured: $0, invoke: model.invoke) }
            .sheet(isPresented: $showingPanes) { panePicker }
            .sheet(isPresented: $showingMetadata) {
                if let snapshot = model.state?.snapshot { EndpointMetadataSettings(snapshot: snapshot) }
            }
            .sheet(isPresented: $showingTheme) { EndpointThemeSheet(storedTheme: $theme, borders: $borders) }
            .sheet(isPresented: $showingMachines) {
                MachinePickerSheet(state: connection.machines, select: connection.selectMachine,
                                   openAgent: connection.selectMachineAgent, perform: connection.requestMachines)
            }
            .sheet(isPresented: $showingLayout) {
                if let snapshot = layoutSnapshot, let viewID = layoutViewID {
                    EndpointLayoutSheet(snapshot: snapshot, owningViewID: viewID, currentViewID: model.identity?.viewID,
                        currentBootID: model.state?.snapshot?.bootID, result: model.state?.layoutResult, busy: model.busy,
                        methods: Set(model.state?.methods ?? []), submit: model.performLayout)
                }
            }
            .sheet(isPresented: $showingWorktrees) {
                if let snapshot = worktreeSnapshot {
                    EndpointWorktreesSheet(snapshot: snapshot, currentBootID: model.state?.snapshot?.bootID,
                        result: model.state?.worktreeResult, busy: model.busy,
                        methods: Set(model.state?.methods ?? []), submit: model.performWorktree)
                }
            }
            .sheet(isPresented: $showingAgentLaunch) {
                if let snapshot = launchSnapshot {
                    EndpointAgentLaunchSheet(snapshot: snapshot, currentBootID: model.state?.snapshot?.bootID,
                        owningViewID: launchViewID, currentViewID: model.identity?.viewID,
                        result: model.state?.agentLaunchResult, busy: model.busy, submit: { model.launchAgent($0) })
                }
            }
            .sheet(isPresented: $showingPlugins) {
                if let snapshot = model.state?.snapshot {
                    EndpointPluginSheet(snapshot: snapshot, surface: model.state?.surface, result: model.state?.pluginResult,
                        busy: model.busy, methods: Set(model.state?.methods ?? []), submit: model.performPlugin)
                }
            }
            .sheet(isPresented: $showingNotifications) {
                EndpointNotificationSettings(notifications: model.state?.notifications ?? [])
            }
            .sheet(isPresented: $showingTextTools) {
                if let snapshot = textSnapshot {
                    EndpointTextToolsSheet(mode: textMode, snapshot: snapshot, surface: model.state?.surface,
                        currentBootID: model.state?.snapshot?.bootID, result: model.state?.terminalResult,
                        busy: model.busy, submit: model.performTerminalAction)
                }
            }
            .modifier(EndpointNotificationPresentation(notifications: model.state?.notifications ?? []))
            .modifier(EndpointLinkPresentation(links: links, result: model.state?.pluginResult, surface: model.state?.surface))
            .onChange(of: model.identity) { _, _ in links.reset() }
            .onAppear { if scenePhase == .active { connection.openEndpointView() } }
            .onDisappear { connection.closeEndpointView() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { connection.closeEndpointView() }
                else if phase == .active { connection.openEndpointView() }
            }
        }
        .preferredColorScheme(appearance.colorScheme ?? systemColorScheme)
    }

    private func arrow(_ key: EndpointKey.Special) -> String {
        switch key {
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        case .up: return "arrow.up"
        default: return "arrow.down"
        }
    }

    private var panePicker: some View {
        NavigationStack {
            List {
                if let snapshot = model.state?.snapshot {
                    if snapshot.agentViewLabel != nil {
                        EndpointAgentViewRows(snapshot: snapshot, busy: model.busy, select: {
                            model.command(.focusPane($0)); showingPanes = false
                        }, palette: palette)
                    } else {
                    ForEach(snapshot.workspaces.indices, id: \.self) { index in
                        let workspace = snapshot.workspaces[index].objectValue ?? [:]
                        Section {
                            ForEach(snapshot.panes.indices, id: \.self) { paneIndex in
                                let pane = snapshot.panes[paneIndex].objectValue ?? [:]
                                if pane["workspace_id"] == workspace["workspace_id"], let id = pane["pane_id"]?.stringValue {
                                    Button {
                                        model.command(.focusPane(id))
                                        showingPanes = false
                                    } label: {
                                        VStack(alignment: .leading) {
                                            if let agent = snapshot.agents.first(where: { $0.objectValue?["pane_id"]?.stringValue == id }) {
                                                EndpointMetadataRows(record: agent, kind: .agent, snapshot: snapshot, foreground: palette.foreground)
                                            } else {
                                                Text(pane["label"]?.stringValue ?? Night.repoName(pane["foreground_cwd"]?.stringValue) ?? "Terminal")
                                            }
                                            Text(id).font(.caption).foregroundStyle(palette.secondary)
                                        }
                                    }.disabled(model.busy || model.error != nil)
                                    .foregroundStyle(palette.foreground)
                                    .listRowBackground(snapshot.focusedPaneID == id
                                        ? palette.color("active_row_bg", fallback: .clear) : palette.sidebar)
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
            .navigationTitle("Panes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Panes").font(.headline).foregroundStyle(palette.foreground)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            .toolbarBackground(palette.sidebar, for: .navigationBar)
            .toolbarBackground(theme.isEmpty ? .automatic : .visible, for: .navigationBar)
            .toolbarColorScheme(palette.sidebarColorScheme, for: .navigationBar)
        }
    }
}

private struct EndpointPhoneActions: View {
    @ObservedObject var model: EndpointPhoneModel

    var body: some View {
        Group {
            if let snapshot = model.state?.snapshot {
                if let workspace = snapshot.focusedWorkspaceID {
                    action("New Tab", .createTab(workspaceID: workspace))
                    action("New Workspace", .createWorkspace(sourceWorkspaceID: workspace))
                }
                if let pane = snapshot.focusedPaneID {
                    if model.state?.methods.contains("pane.scroll") == true {
                    Button("History Page Up") { model.scrollPage(1) }
                    Button("History Page Down") { model.scrollPage(-1) }
                    Button("Return to Live Output") { model.scroll(paneID: pane, offset: 0) }
                    }
                    Divider()
                    action("Split Right", .split(paneID: pane, direction: .right))
                    action("Split Down", .split(paneID: pane, direction: .down))
                    action("Zoom Pane", .zoom(pane))
                    action("Close Pane", .closePane(pane))
                }
                if let tab = snapshot.focusedTabID { action("Close Tab", .closeTab(tab)) }
            }
        }.disabled(model.busy || model.error != nil)
    }

    private func action(_ title: String, _ command: EndpointBridgeCommand) -> some View {
        Button(title) { model.command(command) }
            .disabled(model.state?.methods.contains(command.rpc.method) != true)
    }
}

final class EndpointPhoneTerminalView: PhoneLinkTerminalView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        optionAsMetaKey = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        optionAsMetaKey = false
    }

    var semanticInput: ((EndpointBridgeInput) -> Void)?
    var clipboard = EndpointClipboard()

    override func copy(_ sender: Any?) {
        guard let selected = getSelection(), !selected.isEmpty else { return }
        // Keep the native selection and its gesture state available for an explicit retry.
        clipboard.copy(selected)
    }

    override func paste(_ sender: Any?) {
        if let text = UIPasteboard.general.string { semanticInput?(.paste(text)) }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var remaining = Set<UIPress>()
        for press in presses {
            if markedTextRange == nil, let key = press.key, let input = EndpointPhoneKeyboard.input(key) {
                semanticInput?(input)
            } else { remaining.insert(press) }
        }
        if !remaining.isEmpty { super.pressesBegan(remaining, with: event) }
    }
}

@MainActor
private final class EndpointPhoneTerminalReference: ObservableObject {
    weak var terminal: EndpointPhoneTerminalView?
}

private struct EndpointPhoneTerminal: UIViewRepresentable {
    @ObservedObject var model: EndpointPhoneModel
    let theme: String
    let links: EndpointNativeLinks
    let clipboard: EndpointClipboard
    @Environment(\.colorScheme) private var colorScheme

    let reference: EndpointPhoneTerminalReference

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> EndpointPhoneTerminalView {
        let view = EndpointPhoneTerminalView(frame: .zero)
        view.clipboard = clipboard
        // The endpoint owns history. Local resize must not retain old screen rows.
        view.getTerminal().changeScrollback(nil)
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.terminalDelegate = context.coordinator
        view.semanticInput = { [weak model] input in model?.input(input) }
        view.endpointLinkAt = { [weak model, weak view] url, point in
            guard let model, let surface = model.state?.surface, let view else { return true }
            let size = view.getOptimalFrameSize()
            guard size.width > 0, size.height > 0 else { return true }
            return links.activate(url: url, column: Int(floor(point.x * CGFloat(surface.grid.width) / size.width)),
                row: Int(floor(point.y * CGFloat(surface.grid.height) / size.height)), surface: surface, submit: model.performPlugin)
        }
        view.showsVerticalScrollIndicator = false
        view.isScrollEnabled = false
        context.coordinator.scrollGesture = EndpointPhoneScrollGesture(terminal: view, model: model)
        context.coordinator.mouseGesture = EndpointPhoneMouseGesture(terminal: view, model: model)
        view.allowMouseReporting = false
        reference.terminal = view
        return view
    }

    func updateUIView(_ view: EndpointPhoneTerminalView, context: Context) {
        let coordinator = context.coordinator
        let dark = colorScheme == .dark
        let appearanceChanged = coordinator.dark != dark || coordinator.theme != theme
        if appearanceChanged {
            EndpointTerminalAppearance.apply(view, dark: dark, theme: EndpointTheme.stored(theme))
            coordinator.dark = dark
            coordinator.theme = theme
        }
        if coordinator.identity != model.identity {
            coordinator.identity = model.identity
            coordinator.renderKey = nil
            coordinator.grid = nil
            view.feed(text: "\u{1b}[2J\u{1b}[H")
        }
        guard let surface = model.state?.surface else { return }
        let renderKey = EndpointSurfaceRenderKey(surface)
        guard appearanceChanged || coordinator.renderKey != renderKey else { return }
        coordinator.painting = true
        defer { coordinator.painting = false }
        view.pinGridSize(cols: Int(surface.grid.width), rows: Int(surface.grid.height))
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
        let model: EndpointPhoneModel
        var identity: EndpointViewIdentity?
        var renderKey: EndpointSurfaceRenderKey?
        var grid: EndpointGrid?
        var graphics = EndpointGraphicsEncoder()
        var painting = false
        var dark: Bool?
        var theme: String?
        var scrollGesture: EndpointPhoneScrollGesture?
        var mouseGesture: EndpointPhoneMouseGesture?
        init(model: EndpointPhoneModel) { self.model = model }
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            if !painting, let input = EndpointBridgeInput.terminalBytes(data) { model.input(input) }
        }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            if !painting { model.resize(columns: newCols, rows: newRows) }
        }
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            TerminalLink.open(link)
        }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

enum EndpointPhoneKeyboard {
    static func input(_ key: UIKey) -> EndpointBridgeInput? {
        guard !key.modifierFlags.contains(.command) else { return nil }
        var modifiers: UInt8 = 0
        if key.modifierFlags.contains(.shift) { modifiers |= 1 }
        if key.modifierFlags.contains(.control) { modifiers |= 2 }
        if key.modifierFlags.contains(.alternate) { modifiers |= 4 }
        let specials: [UIKeyboardHIDUsage: EndpointKey.Special] = [
            .keyboardReturnOrEnter: .enter, .keypadEnter: .enter, .keyboardEscape: .escape,
            .keyboardDeleteOrBackspace: .backspace, .keyboardDeleteForward: .delete,
            .keyboardLeftArrow: .left, .keyboardRightArrow: .right, .keyboardUpArrow: .up, .keyboardDownArrow: .down,
            .keyboardHome: .home, .keyboardEnd: .end, .keyboardPageUp: .pageUp, .keyboardPageDown: .pageDown,
            .keyboardTab: modifiers & 1 != 0 ? .backTab : .tab,
        ]
        if let special = specials[key.keyCode] { return .special(special, modifiers: modifiers) }
        if (58...69).contains(key.keyCode.rawValue) { return .function(UInt8(key.keyCode.rawValue - 57), modifiers: modifiers) }
        if modifiers & 2 != 0, key.charactersIgnoringModifiers.unicodeScalars.count == 1 {
            return .character(key.charactersIgnoringModifiers, modifiers: modifiers)
        }
        return nil
    }
}
