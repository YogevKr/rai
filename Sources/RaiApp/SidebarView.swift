import RaiCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let raiTab = UTType(exportedAs: "gr.krig.rai.tab")
    static let raiWorkspace = UTType(exportedAs: "gr.krig.rai.workspace")
}

struct SidebarView: View {
    @ObservedObject var model: RaiModel
    @State private var broadcastPresented = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if let snapshot = model.snapshot {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                        ForEach(snapshot.workspaces) { workspace in
                            let allTabs = tabs(in: snapshot, of: workspace)
                            // A collapsed space hides everything but its
                            // attention-needing tabs (and the selected one) —
                            // same predicate as the global "only needs you".
                            let collapsed = model.isWorkspaceCollapsed(workspace.workspaceID)
                            let visibleTabs = allTabs.filter {
                                AttentionFilter.includes(
                                    status: $0.agentStatus,
                                    id: $0.tabID,
                                    selectedID: model.selectedTabID,
                                    onlyNeedsYou: model.onlyNeedsYou || collapsed
                                )
                            }
                            let focused = snapshot.focusedWorkspaceID == workspace.workspaceID
                            // Every space renders the same way — header + tab
                            // rows — whether it holds one tab or many.
                            if collapsed || !visibleTabs.isEmpty {
                                Section {
                                    ForEach(visibleTabs) { tab in
                                        AgentRow(
                                            model: model,
                                            tab: tab,
                                            label: snapshot.displayLabel(for: tab),
                                            selected: model.selectedTabID == tab.tabID,
                                            onSelect: { model.select(tab: tab) },
                                            onPaneDragHover: {
                                                model.previewTabDuringPaneDrag(tab)
                                            },
                                            onBroadcast: { broadcastPresented = true }
                                        )
                                    }
                                } header: {
                                    WorkspaceHeader(
                                        model: model,
                                        workspace: workspace,
                                        focusedInHerdr: focused,
                                        collapsed: collapsed,
                                        hiddenCount: allTabs.count - visibleTabs.count,
                                        onToggleCollapse: {
                                            model.toggleWorkspaceCollapsed(workspace.workspaceID)
                                        }
                                    )
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 16)
                }
                .scrollIndicators(.hidden)
                // Right-click on empty sidebar space: the create actions.
                .contextMenu {
                    Button("New Tab") { model.newTab() }
                    Button("New Space") { model.newWorkspace() }
                }
            } else {
                Spacer()
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finding the herd…")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            }
            Divider().overlay(Theme.hairline)
            attentionFooter
        }
        // A little top breathing room, then fill up to the window top (under the
        // transparent title bar); the header's leading padding reserves room for
        // the traffic lights.
        .padding(.top, Theme.contentTopInset)
        .ignoresSafeArea(.container, edges: .top)
        // Linear: a solid sidebar panel, separated from the content by a hairline
        // (the region-defining device), with a whisper-subtle top highlight.
        .background(Theme.sidebar.ignoresSafeArea())
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.hairline).frame(width: 1).ignoresSafeArea()
        }
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.topHighlight).frame(height: 1).ignoresSafeArea()
        }
        .sheet(item: $model.renameRequest) { request in
            RenameSheet(model: model, request: request)
        }
        .sheet(item: $model.statusExplanation) { _ in
            StatusExplanationSheet(model: model)
        }
        .sheet(item: $model.worktreeCreateRequest) { request in
            NewWorktreeSheet(model: model, request: request)
        }
        .sheet(item: $model.worktreeOpenRequest) { _ in
            OpenWorktreeSheet(model: model)
        }
        .sheet(item: $model.newSessionRequest) { _ in
            NewSessionSheet(model: model)
        }
        .sheet(item: $model.remoteHerdRequest) { _ in
            RemoteHerdSheet(model: model)
        }
        .alert(item: $model.workspacePendingClose) { workspace in
            Alert(
                title: Text("Close “\(workspace.label)”?"),
                message: Text(
                    "This space contains \(workspace.tabCount) agents. "
                        + "Closing it will end every tab in the space."
                ),
                primaryButton: .destructive(Text("Close Space")) {
                    model.confirmCloseWorkspace()
                },
                secondaryButton: .cancel()
            )
        }
    }

    // herdr's canonical tab order is the snapshot array order (tab.move reorders
    // the array, not the `number` field) — preserve it, don't re-sort by number.
    private func tabs(in snapshot: SessionSnapshot, of workspace: Workspace) -> [HerdrTab] {
        snapshot.tabs.filter { $0.workspaceID == workspace.workspaceID }
    }

    private var header: some View {
        HStack(spacing: 8) {
            sessionMenu
            Spacer(minLength: 6)
            Menu {
                Button {
                    model.newTab()
                } label: {
                    Label("New Tab", systemImage: "plus.rectangle")
                }
                Button {
                    model.newWorkspace()
                } label: {
                    Label("New Space", systemImage: "square.stack.3d.up")
                }
                Divider()
                Button {
                    if let workspace = model.selectedWorkspace {
                        model.beginCreateWorktree(from: workspace)
                    }
                } label: {
                    Label("New Worktree…", systemImage: "arrow.triangle.branch")
                }
                .disabled(model.selectedWorkspace?.worktree == nil)
                Button {
                    if let workspace = model.selectedWorkspace {
                        model.beginOpenWorktree(from: workspace)
                    }
                } label: {
                    Label("Open Worktree…", systemImage: "folder.badge.plus")
                }
                .disabled(model.selectedWorkspace?.worktree == nil)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New tab, space, or worktree")
            Button {
                model.onlyNeedsYou.toggle()
            } label: {
                Image(
                    systemName: model.onlyNeedsYou
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle"
                )
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(
                    model.onlyNeedsYou ? Theme.accent : Theme.textSecondary
                )
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(model.onlyNeedsYou ? Theme.accent.opacity(0.12) : .clear)
                )
            }
            .buttonStyle(.plain)
            .help("Only needs-you")
            .accessibilityLabel("Only needs-you")
            ConnectionPill(state: model.connectionState)
        }
        .padding(.leading, 78)
        .padding(.trailing, 12)
        .frame(height: Theme.headerHeight)
        .sheet(isPresented: $broadcastPresented) {
            BroadcastSheet(model: model)
        }
        .alert(item: $model.worktreeAlert) { alert in
            worktreeAlert(alert)
        }
    }

    private var sessionMenu: some View {
        Menu {
            Section("Local Sessions") {
                ForEach(model.sessions) { session in
                    Button {
                        model.switchSession(session)
                    } label: {
                        Label(
                            session.name,
                            systemImage: model.isCurrentSession(session)
                                ? "checkmark.circle.fill"
                                : (session.isRunning ? "circle.fill" : "circle")
                        )
                    }
                    .disabled(
                        model.isCurrentSession(session) && session.isRunning
                    )
                }
            }

            if model.sessions.contains(where: \.isRunning) {
                Menu("Stop Session") {
                    ForEach(model.sessions.filter(\.isRunning)) { session in
                        Button(session.name, role: .destructive) {
                            model.requestStopSession(session)
                        }
                    }
                }
            }

            Divider()
            Button {
                model.beginCreateSession()
            } label: {
                Label("New Session…", systemImage: "plus")
            }
            Button {
                model.beginRemoteConnection()
            } label: {
                Label("Connect to Remote…", systemImage: "network")
            }
            if model.remoteTarget != nil {
                Button(role: .destructive) {
                    model.disconnectRemote()
                } label: {
                    Label("Disconnect Remote", systemImage: "xmark.circle")
                }
            }
            Divider()
            Button {
                model.refreshSessions()
            } label: {
                Label("Refresh Sessions", systemImage: "arrow.clockwise")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.remoteTarget == nil ? "externaldrive" : "network")
                    .font(.system(size: 9.5, weight: .medium))
                Text(model.currentSessionDisplayName)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .foregroundStyle(Theme.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch Herdr session")
        .alert(item: $model.sessionAlert) { alert in
            sessionAlert(alert)
        }
    }

    private var attentionFooter: some View {
        HStack(spacing: 8) {
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings")

            if model.blockedAgentCount > 0 {
                Button {
                    model.onlyNeedsYou = true
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Theme.status(.blocked))
                            .frame(width: 6, height: 6)
                        Text(
                            model.blockedAgentCount == 1
                                ? "1 needs you"
                                : "\(model.blockedAgentCount) need you"
                        )
                        .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Show only agents that need you")
            }

            Spacer()

            Button {
                model.notificationsMuted.toggle()
            } label: {
                Image(
                    systemName: model.notificationsMuted
                        ? "bell.slash.fill"
                        : "bell.fill"
                )
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(
                    model.notificationsMuted
                        ? Theme.textTertiary
                        : Theme.textSecondary
                )
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            model.notificationsMuted
                                ? Theme.interactionWash(opacity: 0.035)
                                : .clear
                        )
                )
            }
            .buttonStyle(.plain)
            .help(
                model.notificationsMuted
                    ? "Agent notifications are muted"
                    : "Mute agent notifications"
            )
            .accessibilityLabel(
                model.notificationsMuted
                    ? "Unmute agent notifications"
                    : "Mute agent notifications"
            )
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
    }

    private func worktreeAlert(_ alert: WorktreeAlert) -> Alert {
        switch alert.kind {
        case .confirmRemoval(let workspace):
            let path = workspace.worktree?.checkoutPath ?? workspace.label
            return Alert(
                title: Text("Remove Worktree?"),
                message: Text(
                    "This closes “\(workspace.label)” and deletes its checkout at \(path). "
                        + "The Git branch is not deleted."
                ),
                primaryButton: .destructive(Text("Remove Worktree")) {
                    model.confirmRemoveWorktree(workspace, force: false)
                },
                secondaryButton: .cancel()
            )
        case .confirmForcedRemoval(let workspace):
            let path = workspace.worktree?.checkoutPath ?? workspace.label
            return Alert(
                title: Text("Worktree Has Local Changes"),
                message: Text(
                    "Herdr reports modified or untracked files at \(path). "
                        + "Force removal permanently deletes those files."
                ),
                primaryButton: .destructive(Text("Force Remove")) {
                    model.confirmRemoveWorktree(workspace, force: true)
                },
                secondaryButton: .cancel()
            )
        case .error(let title, let message):
            return Alert(
                title: Text(title),
                message: Text(message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private func sessionAlert(_ alert: SessionAlert) -> Alert {
        switch alert.kind {
        case .confirmStop(let session, let isCurrent):
            return Alert(
                title: Text("Stop “\(session.name)”?"),
                message: Text(
                    isCurrent
                        ? "You are viewing this session. Its panes will stop and rai "
                            + "will disconnect from it."
                        : "This stops every pane running in the session."
                ),
                primaryButton: .destructive(Text("Stop Session")) {
                    model.confirmStopSession(session)
                },
                secondaryButton: .cancel()
            )
        case .error(let title, let message):
            return Alert(
                title: Text(title),
                message: Text(message),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

// Shared row chrome so workspace-rows and agent-rows are pixel-identical.
private struct SidebarRowChrome: ViewModifier {
    let selected: Bool
    let hovering: Bool
    var indent: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(.leading, 11 + indent)
            .padding(.trailing, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
                    .fill(
                        selected
                            ? Theme.accent.opacity(0.14)
                            : (hovering ? Theme.interactionWash(opacity: 0.04) : .clear)
                    )
            }
            .overlay(alignment: .leading) {
                if selected {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Theme.accent)
                        .frame(width: 3, height: 22)
                        .shadow(color: Theme.accent.opacity(0.6), radius: 4)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            .animation(.easeOut(duration: 0.16), value: selected)
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// A slim accent insertion line at a row's top edge while a reorder-drag hovers it.
private struct SidebarDropIndicator: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if active {
                    Capsule()
                        .fill(Theme.accent)
                        .frame(height: 2)
                        .padding(.horizontal, 8)
                        .shadow(color: Theme.accent.opacity(0.6), radius: 3)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.1), value: active)
    }
}

// A borderless text field for editing a name in place. Commits on Return or when
// focus leaves; cancels on Escape. A one-shot guard keeps Return (which also
// resigns focus) from committing twice.
private struct InlineRenameField: View {
    let font: Font
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var draft: String
    @State private var finished = false
    @FocusState private var focused: Bool

    init(
        initial: String,
        font: Font,
        onCommit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.font = font
        self.onCommit = onCommit
        self.onCancel = onCancel
        _draft = State(initialValue: initial)
    }

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(Theme.textPrimary)
            .focused($focused)
            .onAppear { focused = true }
            .onSubmit { finish(commit: true) }
            .onExitCommand { finish(commit: false) }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { finish(commit: true) }
            }
    }

    private func finish(commit: Bool) {
        guard !finished else { return }
        finished = true
        if commit { onCommit(draft) } else { onCancel() }
    }
}

// Shared two-line row content: a status dot, a title, and a muted
// "status · context" subtitle — the mission-control row shape.
private struct SidebarRowLabel<Trailing: View>: View {
    let status: AgentStatus
    let title: String
    let subtitle: String
    let selected: Bool
    let focusedInHerdr: Bool
    var isSpace: Bool = false
    var editing: Bool = false
    var onCommitRename: (String) -> Void = { _ in }
    var onCancelRename: () -> Void = {}
    var onRename: () -> Void = {}
    @ViewBuilder var trailing: () -> Trailing

    private var subtitleLine: Text {
        let context = subtitle.trimmingCharacters(in: .whitespaces)
        if status == .unknown {
            return Text(context.isEmpty ? "—" : context).foregroundColor(Theme.textTertiary)
        }
        return Text(Theme.statusLabel(status)).foregroundColor(Theme.status(status))
            + Text(context.isEmpty ? "" : "  ·  \(context)").foregroundColor(Theme.textTertiary)
    }

    var body: some View {
        HStack(spacing: 10) {
            if isSpace {
                Image(systemName: "square.stack")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            StatusDot(status: status)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if editing {
                        InlineRenameField(
                            initial: title,
                            font: .system(size: 13, weight: selected ? .semibold : .medium),
                            onCommit: onCommitRename,
                            onCancel: onCancelRename
                        )
                    } else {
                        Text(title)
                            .font(.system(size: 13, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            // Double-click the name to rename. A *simultaneous*
                            // gesture on the title doesn't consume the row's drag,
                            // so tab/space reordering keeps working.
                            .simultaneousGesture(
                                TapGesture(count: 2).onEnded { onRename() }
                            )
                        if focusedInHerdr {
                            Circle().fill(Theme.accent).frame(width: 4, height: 4)
                                .help("Focused in Herdr")
                        }
                    }
                }
                subtitleLine
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            trailing()
        }
    }
}

private struct WorktreeTag: View {
    let worktree: WorkspaceWorktree

    var body: some View {
        HStack(spacing: 3) {
            if worktree.isLinkedWorktree {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 8))
            }
            Text(identity).lineLimit(1)
        }
        .font(.system(size: 9.5, weight: .medium, design: .rounded))
        .foregroundStyle(Theme.textTertiary)
        .help(worktree.checkoutPath)
    }

    private var identity: String {
        guard worktree.isLinkedWorktree else { return worktree.repoName }
        let checkoutName = URL(fileURLWithPath: worktree.checkoutPath).lastPathComponent
        return checkoutName.isEmpty ? worktree.repoName : checkoutName
    }
}

private struct WorkspaceHeader: View {
    @ObservedObject var model: RaiModel
    let workspace: Workspace
    let focusedInHerdr: Bool
    var collapsed: Bool = false
    var hiddenCount: Int = 0
    var onToggleCollapse: () -> Void = {}

    @State private var dropTargeted = false

    private var showWorktreeTag: Bool {
        guard let worktree = workspace.worktree else { return false }
        return worktree.isLinkedWorktree
            || worktree.repoName.caseInsensitiveCompare(workspace.label) != .orderedSame
    }

    var body: some View {
        HStack(spacing: 7) {
            Button(action: onToggleCollapse) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Expand space" : "Collapse space")
            Image(systemName: "square.stack")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            if model.inlineRename == .workspace(workspace.workspaceID) {
                InlineRenameField(
                    initial: workspace.label,
                    font: .system(size: 10, weight: .semibold),
                    onCommit: { model.commitInlineRename(workspace: workspace, to: $0) },
                    onCancel: { model.cancelInlineRename() }
                )
            } else {
                Text(workspace.label.uppercased())
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .simultaneousGesture(
                        TapGesture(count: 2)
                            .onEnded { model.beginInlineRename(workspace: workspace) }
                    )
                if focusedInHerdr {
                    Circle().fill(Theme.accent).frame(width: 4, height: 4)
                        .help("Focused in Herdr")
                }
            }
            Spacer(minLength: 4)
            if collapsed, hiddenCount > 0 {
                Text("\(hiddenCount) hidden")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
            } else if showWorktreeTag, let worktree = workspace.worktree {
                WorktreeTag(worktree: worktree)
            } else {
                Text("\(workspace.tabCount)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 16)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A faint band + bottom hairline so a space header reads as a group
        // divider, clearly distinct from the flat tab rows beneath it.
        .background {
            Theme.sidebar
            Color.white.opacity(0.025)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
        .modifier(SidebarDropIndicator(active: dropTargeted))
        .contentShape(Rectangle())
        .onTapGesture { model.select(workspace: workspace) }
        .onDrag {
            model.draggedWorkspaceID = workspace.workspaceID
            return sidebarDragProvider(id: workspace.workspaceID, type: .raiWorkspace)
        }
        .onDrop(
            of: [.raiWorkspace],
            delegate: SidebarReorderDropDelegate(
                targetID: workspace.workspaceID,
                type: .raiWorkspace,
                model: model,
                targeted: $dropTargeted
            )
        )
        .contextMenu {
            Button("New Tab in Space") { model.newTab(inWorkspace: workspace.workspaceID) }
            Button("New Space") { model.newWorkspace() }
            Divider()
            Button("Focus") { model.select(workspace: workspace) }
            Button("Rename") { model.beginRename(workspace: workspace) }
            Button("Close", role: .destructive) {
                model.requestClose(workspace: workspace)
            }
            let actions = model.pluginActions(for: .workspace)
            if !actions.isEmpty {
                Menu("Plugin Actions") {
                    ForEach(actions) { action in
                        Button(action.title) {
                            model.invokePluginAction(action, forWorkspace: workspace)
                        }
                        .help(action.description ?? action.title)
                    }
                }
            }
            Divider()
            Button("New Worktree…") {
                model.beginCreateWorktree(from: workspace)
            }
            .disabled(workspace.worktree == nil)
            Button("Open Worktree…") {
                model.beginOpenWorktree(from: workspace)
            }
            .disabled(workspace.worktree == nil)
            if workspace.worktree?.isLinkedWorktree == true {
                Button("Remove Worktree…", role: .destructive) {
                    model.requestRemoveWorktree(workspace)
                }
            }
            Divider()
            Button("Explain Status") { model.explainStatus(workspace: workspace) }
        }
        .help(workspace.worktree?.checkoutPath ?? workspace.label)
    }
}

private struct AgentRow: View {
    @ObservedObject var model: RaiModel
    let tab: HerdrTab
    let label: String
    let selected: Bool
    let onSelect: () -> Void
    let onPaneDragHover: () -> Void
    let onBroadcast: () -> Void

    @State private var hovering = false
    @State private var dropTargeted = false

    private var subtitleContext: String {
        guard let cwd = model.snapshot?.panes.first(where: { $0.tabID == tab.tabID })?.cwd else {
            return ""
        }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    var body: some View {
        SidebarRowLabel(
            status: tab.agentStatus,
            title: label,
            subtitle: subtitleContext,
            selected: selected,
            focusedInHerdr: false,
            editing: model.inlineRename == .tab(tab.tabID),
            onCommitRename: { model.commitInlineRename(tab: tab, to: $0) },
            onCancelRename: { model.cancelInlineRename() },
            onRename: { model.beginInlineRename(tab: tab) }
        ) {
            let bgTasks = model.backgroundWork(forTab: tab.tabID)
            if !bgTasks.isEmpty {
                // The session registered background shells/monitors: an "idle"
                // agent with this badge is waiting, not finished.
                HStack(spacing: 3) {
                    Image(systemName: "clock.arrow.2.circlepath")
                    Text("\(bgTasks.count)")
                }
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Theme.status(.working))
                .help(
                    "Waiting on background work:\n"
                        + bgTasks.map { "▸ " + $0.displaySummary }.joined(separator: "\n")
                )
            }
            if tab.paneCount > 1 {
                HStack(spacing: 3) {
                    Image(systemName: "rectangle.split.2x1")
                    Text("\(tab.paneCount)")
                }
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
            }
            // Broadcast is a tab action, so it only appears on the selected tab.
            if selected {
                Button(action: onBroadcast) {
                    Image(systemName: "megaphone")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Broadcast to every pane in this tab")
            }
        }
        // Indent tabs inside the chrome (not via outer padding) so the drag/drop
        // modifiers still wrap the full-width row and reordering keeps working.
        .modifier(SidebarRowChrome(selected: selected, hovering: hovering, indent: 14))
        .modifier(SidebarDropIndicator(active: dropTargeted))
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        // Row is a plain view (not a Button) so `.onDrag` can start a drag on
        // macOS — re-add the button semantics `.onTapGesture` drops for VoiceOver.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onSelect() }
        .onHover { hovering = $0 }
        .onDrag {
            model.draggedTabID = tab.tabID
            return sidebarDragProvider(id: tab.tabID, type: .raiTab)
        }
        // ONE drop destination per row: it reorders tabs AND previews the tab
        // under a pane drag. A second stacked `.onDrop` would shadow this one
        // (macOS honors only the innermost), which is what broke reordering.
        .onDrop(
            of: [.raiTab, UTType.raiPane],
            delegate: SidebarReorderDropDelegate(
                targetID: tab.tabID,
                type: .raiTab,
                model: model,
                targeted: $dropTargeted,
                onPaneDragHover: onPaneDragHover
            )
        )
        .contextMenu {
            Button("New Tab") { model.newTab(inWorkspace: tab.workspaceID) }
            Divider()
            Button("Focus", action: onSelect)
            Button("Rename") { model.beginRename(tab: tab) }
            Button("Close", role: .destructive) { model.close(tab: tab) }
            let actions = model.pluginActions(for: .tab)
            if !actions.isEmpty {
                Menu("Plugin Actions") {
                    ForEach(actions) { action in
                        Button(action.title) {
                            model.invokePluginAction(action, forTab: tab)
                        }
                        .help(action.description ?? action.title)
                    }
                }
            }
            Divider()
            if !model.backgroundWork(forTab: tab.tabID).isEmpty {
                Button("Show Background Work…") { model.showBackgroundWork(forTab: tab) }
            }
            Button("Explain Status") { model.explainStatus(tab: tab) }
        }
    }
}

private struct RenameSheet: View {
    @ObservedObject var model: RaiModel
    let request: RenameRequest

    @State private var label: String
    @FocusState private var labelFocused: Bool

    init(model: RaiModel, request: RenameRequest) {
        self.model = model
        self.request = request
        _label = State(initialValue: request.initialLabel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(request.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            TextField("Name", text: $label)
                .textFieldStyle(.roundedBorder)
                .focused($labelFocused)
                .onSubmit(commit)

            HStack {
                Spacer()
                Button("Cancel") { model.renameRequest = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 380)
        .background(Theme.raised)
        .onAppear { labelFocused = true }
        .onExitCommand { model.renameRequest = nil }
    }

    private func commit() {
        model.commitRename(request, label: label)
    }
}

private struct NewWorktreeSheet: View {
    @ObservedObject var model: RaiModel
    let request: WorktreeCreateRequest

    @State private var branch = ""
    @State private var base = ""
    @State private var label = ""
    @FocusState private var branchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Worktree")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(request.context.repoName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Text(request.context.checkoutPath)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            VStack(alignment: .leading, spacing: 10) {
                TextField("Branch name", text: $branch)
                    .textFieldStyle(.roundedBorder)
                    .focused($branchFocused)
                    .onSubmit(commit)
                TextField("Base ref (current)", text: $base)
                    .textFieldStyle(.roundedBorder)
                TextField("Space label (optional)", text: $label)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("Cancel") { model.worktreeCreateRequest = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
            }
        }
        .padding(22)
        .frame(width: 430)
        .background(Theme.raised)
        .onAppear { branchFocused = true }
        .onExitCommand { model.worktreeCreateRequest = nil }
    }

    private func commit() {
        model.createWorktree(branch: branch, base: base, label: label)
    }
}

private struct OpenWorktreeSheet: View {
    @ObservedObject var model: RaiModel

    @State private var selectedPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Open Worktree")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let request = model.worktreeOpenRequest {
                    Text(request.context.repoName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Text(request.context.checkoutPath)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Group {
                if let request = model.worktreeOpenRequest {
                    if request.isLoading {
                        HStack(spacing: 9) {
                            ProgressView().controlSize(.small)
                            Text("Loading Git worktrees…")
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let error = request.error {
                        Text(error)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if request.worktrees.isEmpty {
                        Text("No worktrees found for this repository.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(request.worktrees, selection: $selectedPath) { worktree in
                            WorktreePickerRow(worktree: worktree)
                                .tag(worktree.path)
                        }
                        .listStyle(.inset)
                    }
                }
            }
            .frame(height: 280)

            HStack {
                Spacer()
                Button("Cancel") { model.worktreeOpenRequest = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Open") {
                    if let selectedWorktree {
                        model.openWorktree(selectedWorktree)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedWorktree == nil)
            }
        }
        .padding(22)
        .frame(width: 560)
        .background(Theme.raised)
        .onAppear { chooseFirstWorktree() }
        .onChange(of: model.worktreeOpenRequest?.worktrees) { _, _ in
            chooseFirstWorktree()
        }
        .onExitCommand { model.worktreeOpenRequest = nil }
    }

    private var selectedWorktree: HerdrWorktree? {
        guard let selectedPath else { return nil }
        return model.worktreeOpenRequest?.worktrees.first {
            $0.path == selectedPath && !$0.isBare && !$0.isPrunable
        }
    }

    private func chooseFirstWorktree() {
        guard selectedWorktree == nil else { return }
        selectedPath = model.worktreeOpenRequest?.worktrees.first {
            !$0.isBare && !$0.isPrunable
        }?.path
    }
}

private struct WorktreePickerRow: View {
    let worktree: HerdrWorktree

    var body: some View {
        HStack(spacing: 10) {
            Image(
                systemName: worktree.isLinkedWorktree
                    ? "point.3.connected.trianglepath.dotted"
                    : "folder"
            )
            .font(.system(size: 11))
            .foregroundStyle(Theme.textTertiary)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(worktree.branch ?? "Detached HEAD")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    if worktree.openWorkspaceID != nil {
                        Text("OPEN")
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.accent)
                    }
                    if worktree.isPrunable {
                        Text("PRUNABLE")
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                Text(worktree.path)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.vertical, 3)
        .opacity(worktree.isBare || worktree.isPrunable ? 0.5 : 1)
    }
}

private struct NewSessionSheet: View {
    @ObservedObject var model: RaiModel
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New Herdr Session")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            VStack(alignment: .leading, spacing: 7) {
                Text("Name")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                TextField("review", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(create)
            }

            Text("Rai starts a headless Herdr server and switches to it.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)

            HStack {
                Spacer()
                Button("Cancel") {
                    model.newSessionRequest = nil
                }
                .keyboardShortcut(.cancelAction)
                Button("Create") {
                    create()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 420)
        .background(Theme.raised)
    }

    private func create() {
        model.createSession(named: name)
    }
}

private struct RemoteHerdSheet: View {
    @ObservedObject var model: RaiModel
    @State private var target = ""
    @State private var sessionName = "default"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connect to Remote Herd")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            VStack(alignment: .leading, spacing: 7) {
                Text("SSH target")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                TextField("user@host", text: $target)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Herdr session")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                TextField("default", text: $sessionName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(connect)
            }

            Text(
                "Rai discovers the remote session socket, forwards it over SSH, "
                    + "and attaches panes through the local forwarded socket."
            )
            .font(.system(size: 11))
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") {
                    model.remoteHerdRequest = nil
                }
                .keyboardShortcut(.cancelAction)
                Button("Connect") {
                    connect()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(Theme.raised)
    }

    private func connect() {
        model.connectRemote(target: target, sessionName: sessionName)
    }
}

private struct StatusExplanationSheet: View {
    @ObservedObject var model: RaiModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(model.statusExplanation?.title ?? "Explain Status")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button {
                    model.statusExplanation = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Close")
            }

            if let explanation = model.statusExplanation {
                if explanation.isLoading {
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        Text("Asking Herdr…")
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        Text(explanation.text ?? "")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 560, height: 380)
        .background(Theme.raised)
        .onExitCommand { model.statusExplanation = nil }
    }
}

private func sidebarDragProvider(id: String, type: UTType) -> NSItemProvider {
    let provider = NSItemProvider()
    provider.registerDataRepresentation(
        forTypeIdentifier: type.identifier,
        visibility: .ownProcess
    ) { completion in
        completion(id.data(using: .utf8), nil)
        return nil
    }
    return provider
}

// The pure decision core of SidebarReorderDropDelegate, split out (and kept
// SwiftUI-free) so tests can pin the rules without constructing a DropInfo.
enum SidebarDropRules {
    // Whether a row accepts the drop SESSION at all. A reorder session must be
    // accepted purely on payload type: a reorder drag always starts over its
    // own row, and refusing that first validateDrop ends delegate callbacks
    // for the entire session — no other row ever sees the drag. Pane drags are
    // accepted only where a hover-preview handler exists.
    static func acceptsSession(
        paneDrag: Bool,
        hasReorderType: Bool,
        supportsPaneHover: Bool
    ) -> Bool {
        paneDrag ? supportsPaneHover : hasReorderType
    }

    // Whether dropping HERE would actually reorder: a real payload, a
    // different row, and matching workspaces — herdr's tab.move (and
    // RaiModel.moveTab) reject cross-space moves, so don't advertise them.
    // Workspace reorders pass nil for both workspace ids (no constraint).
    static func reorderEligible(
        draggedID: String?,
        targetID: String,
        hasReorderType: Bool,
        sourceWorkspaceID: String?,
        targetWorkspaceID: String?
    ) -> Bool {
        guard hasReorderType, let src = draggedID, src != targetID else {
            return false
        }
        return sourceWorkspaceID == targetWorkspaceID
    }
}

// Reorders a sidebar row onto `targetID`. Reads the dragged id from the model
// synchronously (like PaneDropDelegate) rather than round-tripping through
// NSItemProvider's async load, and drives the drop-target highlight.
//
// It also doubles as the pane-drag hover target: hovering a pane over a row
// previews that row's tab but never accepts the pane. Both roles live in ONE
// delegate because macOS honors only a single `.onDrop` destination per view —
// stacking a second `.onDrop` for panes shadowed the reorder drop entirely.
private struct SidebarReorderDropDelegate: DropDelegate {
    let targetID: String
    let type: UTType
    @ObservedObject var model: RaiModel
    @Binding var targeted: Bool
    var onPaneDragHover: (() -> Void)?

    private var draggedID: String? {
        type == .raiTab ? model.draggedTabID : model.draggedWorkspaceID
    }

    private func isPaneDrag(_ info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.raiPane.identifier])
    }

    private func reorderEligible(_ info: DropInfo) -> Bool {
        var sourceWorkspaceID: String?
        var targetWorkspaceID: String?
        if type == .raiTab {
            let tabs = model.snapshot?.tabs
            sourceWorkspaceID = tabs?.first { $0.tabID == draggedID }?.workspaceID
            targetWorkspaceID = tabs?.first { $0.tabID == targetID }?.workspaceID
            guard sourceWorkspaceID != nil, targetWorkspaceID != nil else {
                return false
            }
        }
        return SidebarDropRules.reorderEligible(
            draggedID: draggedID,
            targetID: targetID,
            hasReorderType: info.hasItemsConforming(to: [type.identifier]),
            sourceWorkspaceID: sourceWorkspaceID,
            targetWorkspaceID: targetWorkspaceID
        )
    }

    func validateDrop(info: DropInfo) -> Bool {
        SidebarDropRules.acceptsSession(
            paneDrag: isPaneDrag(info),
            hasReorderType: info.hasItemsConforming(to: [type.identifier]),
            supportsPaneHover: onPaneDragHover != nil
        )
    }

    func dropEntered(info: DropInfo) {
        if isPaneDrag(info) {
            onPaneDragHover?()
            return
        }
        targeted = reorderEligible(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if isPaneDrag(info) { return DropProposal(operation: .cancel) }
        let ok = reorderEligible(info)
        targeted = ok
        return DropProposal(operation: ok ? .move : .cancel)
    }

    func dropExited(info: DropInfo) {
        targeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        guard !isPaneDrag(info) else { return false }
        defer {
            targeted = false
            model.draggedTabID = nil
            model.draggedWorkspaceID = nil
        }
        guard reorderEligible(info), let src = draggedID else { return false }
        if type == .raiTab {
            model.moveTab(sourceTabID: src, onto: targetID)
        } else {
            model.moveWorkspace(sourceWorkspaceID: src, onto: targetID)
        }
        return true
    }
}

private struct ConnectionPill: View {
    let state: RaiModel.ConnectionState

    var body: some View {
        // Only surface connection state when it's worth knowing — a healthy live
        // link shows nothing (an always-on green dot is just noise).
        if let color {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.6), radius: 3)
                .help(help)
        }
    }

    private var color: Color? {
        switch state {
        case .connecting: Color(hex: 0xF0C33C)
        case .connected: nil
        case .disconnected: Color(hex: 0xFF6B5E)
        }
    }

    private var help: String {
        switch state {
        case .connecting: "Connecting to Herdr…"
        case .connected(let version, let proto): "Live · Herdr \(version), protocol \(proto)"
        case .disconnected(let message): "Offline · \(message)"
        }
    }
}
