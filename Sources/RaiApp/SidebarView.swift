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

    /// Whether the selected space sits in a git checkout. Gates the worktree
    /// actions, which need a repo but not herdr worktree provenance.
    private var hasRepo: Bool {
        guard let workspace = model.selectedWorkspace else { return false }
        return model.worktreeContext(for: workspace) != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.snapshot != nil {
                // Spaces on top, agents below, a divider between them the user
                // drags. The agents panel keeps its header when collapsed.
                GeometryReader { geometry in
                    let panel = agentPanelHeights(in: geometry.size.height)
                    VStack(spacing: 0) {
                        spacesList
                            .frame(height: max(0, geometry.size.height - panel.total))
                        AgentPanelSection(
                            model: model,
                            listHeight: panel.list,
                            onDrag: { translation in
                                guard geometry.size.height > 0 else { return }
                                model.setSidebarSplit(
                                    model.sidebarSplit + translation / geometry.size.height
                                )
                            }
                        )
                        .frame(height: panel.total)
                    }
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
        .modifier(SidebarPresentations(model: model))
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
    }

    /// Collapsed, the panel is just its header; expanded, it takes the share of
    /// the sidebar the divider was dragged to.
    private func agentPanelHeights(in height: CGFloat) -> (total: CGFloat, list: CGFloat) {
        let header = AgentPanelSection.headerHeight
        guard !model.agentPanelCollapsed else { return (header, 0) }
        let list = max(
            AgentPanelSection.minimumListHeight,
            (height * (1 - model.sidebarSplit)) - header
        )
        return (min(height, list + header), list)
    }

    @ViewBuilder
    private var spacesList: some View {
        if let snapshot = model.snapshot {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                    let entries = model.workspaceListEntries
                    let visibleWorkspaceIDs = Set(snapshot.tabs.compactMap { tab in
                        AttentionFilter.includes(
                            status: tab.agentStatus,
                            id: tab.tabID,
                            selectedID: model.selectedTabID,
                            onlyNeedsYou: model.onlyNeedsYou
                        ) ? tab.workspaceID : nil
                    })
                    let expandedEntries = WorkspaceSidebar.entries(
                        in: snapshot,
                        gitStatuses: model.workspaceGitStatuses,
                        collapsedSpaceKeys: [],
                        visibleWorkspaceID: nil
                    )
                    let visibleGroupKeys = Set(expandedEntries.compactMap {
                        visibleWorkspaceIDs.contains($0.workspace.workspaceID)
                            ? $0.groupKey
                            : nil
                    })
                    ForEach(entries) { entry in
                        let workspace = entry.workspace
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
                        let groupHasVisibleTabs = entry.groupKey.map {
                            visibleGroupKeys.contains($0)
                        } ?? false
                        if collapsed || !visibleTabs.isEmpty
                            || (entry.isGroupParent && groupHasVisibleTabs) {
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
                                        onBroadcast: { broadcastPresented = true },
                                        indent: entry.indented ? 32 : 14
                                    )
                                }
                            } header: {
                                WorkspaceHeader(
                                    model: model,
                                    workspace: workspace,
                                    displayLabel: entry.displayLabel,
                                    gitStatus: model.gitStatus(for: workspace),
                                    displayStatus: entry.displayStatus,
                                    focusedInHerdr: focused,
                                    indented: entry.indented,
                                    collapsed: collapsed,
                                    hiddenCount: allTabs.count - visibleTabs.count,
                                    groupKey: entry.isGroupParent ? entry.groupKey : nil,
                                    groupCollapsed: entry.groupCollapsed,
                                    onToggleCollapse: {
                                        model.toggleWorkspaceCollapsed(workspace.workspaceID)
                                    },
                                    onToggleGroup: {
                                        if let key = entry.groupKey {
                                            model.toggleSpaceGroupCollapsed(key)
                                        }
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
        }
    }

    // herdr's canonical tab order is the snapshot array order (tab.move reorders
    // the array, not the `number` field) — preserve it, don't re-sort by number.
    private func tabs(in snapshot: SessionSnapshot, of workspace: Workspace) -> [HerdrTab] {
        snapshot.tabs.filter { $0.workspaceID == workspace.workspaceID }
    }

    /// Every sheet and alert the sidebar owns, lifted off the body so the split
    /// layout above stays readable.
    private struct SidebarPresentations: ViewModifier {
        @ObservedObject var model: RaiModel

        func body(content: Content) -> some View {
            // The broadcast sheet stays on the header — it is presented from
            // there, and two bindings on one flag fight each other.
            content
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
                .disabled(!hasRepo)
                Button {
                    if let workspace = model.selectedWorkspace {
                        model.beginOpenWorktree(from: workspace)
                    }
                } label: {
                    Label("Open Worktree…", systemImage: "folder.badge.plus")
                }
                .disabled(!hasRepo)
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
    let status: WorkspaceGitStatus?
    let worktree: WorkspaceWorktree?

    var body: some View {
        HStack(spacing: 6) {
            if let branch = status?.branch {
                Text(branch)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if status?.isDetached == true {
                Text("detached HEAD")
            } else if let worktree {
                HStack(spacing: 3) {
                    if worktree.isLinkedWorktree {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 8))
                    }
                    Text(worktreeIdentity(worktree)).lineLimit(1)
                }
            }
            if let counts = status?.aheadBehind {
                if counts.ahead > 0 {
                    Text("↑\(counts.ahead)")
                        .foregroundStyle(Theme.status(.done))
                }
                if counts.behind > 0 {
                    Text("↓\(counts.behind)")
                        .foregroundStyle(Theme.status(.blocked))
                }
            }
        }
        .font(.system(size: 10.5, weight: .medium, design: .rounded))
        .foregroundStyle(Theme.textTertiary)
        .help(status?.checkoutPath ?? worktree?.checkoutPath ?? "")
    }

    private func worktreeIdentity(_ worktree: WorkspaceWorktree) -> String {
        guard worktree.isLinkedWorktree else { return worktree.repoName }
        let checkoutName = URL(fileURLWithPath: worktree.checkoutPath).lastPathComponent
        return checkoutName.isEmpty ? worktree.repoName : checkoutName
    }
}

private struct WorkspaceHeader: View {
    @ObservedObject var model: RaiModel
    let workspace: Workspace
    let displayLabel: String
    let gitStatus: WorkspaceGitStatus?
    let displayStatus: AgentStatus
    let focusedInHerdr: Bool
    var indented = false
    var collapsed: Bool = false
    var hiddenCount: Int = 0
    var groupKey: String?
    var groupCollapsed = false
    var onToggleCollapse: () -> Void = {}
    var onToggleGroup: () -> Void = {}

    @State private var dropTargeted = false

    private var showWorktreeFallback: Bool {
        guard let worktree = workspace.worktree else { return false }
        return worktree.isLinkedWorktree
            || worktree.repoName.caseInsensitiveCompare(displayLabel) != .orderedSame
    }

    private var showGitDetails: Bool {
        guard let gitStatus else { return false }
        return gitStatus.branch != nil || gitStatus.isDetached
            || gitStatus.aheadBehind.map {
                $0.ahead > 0 || $0.behind > 0
            } == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Button(action: groupKey == nil ? onToggleCollapse : onToggleGroup) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(
                            .degrees((groupKey == nil ? collapsed : groupCollapsed) ? 0 : 90)
                        )
                        .frame(width: 12, height: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(
                    groupKey == nil
                        ? (collapsed ? "Expand space" : "Collapse space")
                        : (groupCollapsed ? "Expand worktrees" : "Collapse worktrees")
                )
                if groupKey != nil {
                    Button(action: onToggleCollapse) {
                        Image(systemName: "square.stack")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help(collapsed ? "Expand space tabs" : "Collapse space tabs")
                } else {
                    Image(systemName: "square.stack")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                StatusDot(status: displayStatus, size: 6)
                if model.inlineRename == .workspace(workspace.workspaceID) {
                    InlineRenameField(
                        initial: workspace.label,
                        font: .system(size: 10, weight: .semibold),
                        onCommit: { model.commitInlineRename(workspace: workspace, to: $0) },
                        onCancel: { model.cancelInlineRename() }
                    )
                } else {
                    Text(indented ? displayLabel : displayLabel.uppercased())
                        .font(.system(size: 10.5, weight: .bold))
                        .tracking(indented ? 0 : 1.1)
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
                } else {
                    Text("\(workspace.tabCount)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            if !indented, showGitDetails || showWorktreeFallback {
                // Herdr suppresses Git tokens on indented children. Their auto
                // label is already the branch, while a custom name stays custom.
                WorktreeTag(status: gitStatus, worktree: workspace.worktree)
                    .padding(.leading, groupKey == nil ? 43 : 58)
                    .padding(.trailing, 6)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.leading, indented ? 18 : 0)
        .padding(.top, indented ? 6 : 16)
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
        // Headers accept spaces, tabs, and panes. A pane becomes a new tab.
        .onDrop(
            of: [.raiWorkspace, .raiTab, .raiPane],
            delegate: SidebarReorderDropDelegate(
                targetID: workspace.workspaceID,
                type: .raiWorkspace,
                model: model,
                targeted: $dropTargeted,
                paneDropWorkspaceID: workspace.workspaceID
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
    var indent: CGFloat = 14

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
        }
        // Indent tabs inside the chrome (not via outer padding) so the drag/drop
        // modifiers still wrap the full-width row and reordering keeps working.
        .modifier(SidebarRowChrome(selected: selected, hovering: hovering, indent: indent))
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
        // One destination handles tab reorder and pane-to-tab conversion.
        .onDrop(
            of: [.raiTab, UTType.raiPane],
            delegate: SidebarReorderDropDelegate(
                targetID: tab.tabID,
                type: .raiTab,
                model: model,
                targeted: $dropTargeted,
                onPaneDragHover: onPaneDragHover,
                paneDropWorkspaceID: tab.workspaceID,
                paneInsertBeforeTabID: tab.tabID
            )
        )
        .contextMenu {
            Button("New Tab") {
                model.newTab(inWorkspace: tab.workspaceID, afterTabID: tab.tabID)
            }
            Divider()
            Button("Focus", action: onSelect)
            Button("Rename") { model.beginRename(tab: tab) }
            Button("Broadcast…", action: onBroadcast)
            Menu("Move to Space") {
                let others = (model.snapshot?.workspaces ?? [])
                    .filter { $0.workspaceID != tab.workspaceID }
                ForEach(others) { workspace in
                    Button(
                        workspace.label.isEmpty
                            ? "Space \(workspace.number)" : workspace.label
                    ) {
                        model.moveTab(tab.tabID, toWorkspaceID: workspace.workspaceID)
                    }
                }
                if !others.isEmpty { Divider() }
                Button("New Space") { model.moveTabToNewWorkspace(tab.tabID) }
            }
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
        // Hovering the row surfaces the session's own background-work
        // summaries (falls back to the full title for truncated labels).
        // AppKit-backed: SwiftUI's .help() re-registers its tooltip region on
        // every re-render, and herd snapshots re-render rows constantly — the
        // tooltip's arming timer never fires. An NSView's toolTip persists
        // because the view instance is reused across updates.
        .background(ToolTipBackground(text: rowTooltip))
    }

    private var rowTooltip: String {
        let tasks = model.backgroundWork(forTab: tab.tabID)
        guard !tasks.isEmpty else { return label }
        return "Waiting on background work:\n"
            + tasks.map { "▸ " + $0.displaySummary }.joined(separator: "\n")
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
    // for the entire session — no other row ever sees the drag.
    static func acceptsSession(
        paneDrag: Bool,
        hasReorderType: Bool,
        supportsPaneDrop: Bool
    ) -> Bool {
        paneDrag ? supportsPaneDrop : hasReorderType
    }

    // What dropping here does. Same-space tab drops reorder via herdr's
    // tab.move; cross-space drops relocate the tab through the pane.move
    // sequence (RaiModel.moveTab(_:toWorkspaceID:)) since tab.move cannot
    // cross workspaces.
    enum Action: Equatable {
        case reorder
        case moveTabToWorkspace(workspaceID: String, insertBeforeTabID: String?)
        case movePaneToNewTab(workspaceID: String, insertBeforeTabID: String?)
    }

    static func paneAction(
        draggedPaneID: String?,
        targetWorkspaceID: String?,
        insertBeforeTabID: String?
    ) -> Action? {
        guard draggedPaneID != nil, let targetWorkspaceID else { return nil }
        return .movePaneToNewTab(
            workspaceID: targetWorkspaceID,
            insertBeforeTabID: insertBeforeTabID
        )
    }

    // Tab rows: a drop from the same space reorders onto this row; a drop
    // from another space moves the tab here, slotted in front of this row.
    static func tabRowAction(
        draggedTabID: String?,
        targetTabID: String,
        hasTabType: Bool,
        sourceWorkspaceID: String?,
        targetWorkspaceID: String?
    ) -> Action? {
        guard hasTabType,
              let src = draggedTabID,
              src != targetTabID,
              let sourceWorkspaceID,
              let targetWorkspaceID else {
            return nil
        }
        return sourceWorkspaceID == targetWorkspaceID
            ? .reorder
            : .moveTabToWorkspace(
                workspaceID: targetWorkspaceID,
                insertBeforeTabID: targetTabID
            )
    }

    // Workspace headers: a workspace payload reorders spaces; a tab payload
    // from another space appends that tab to this space.
    static func headerAction(
        draggedWorkspaceID: String?,
        draggedTabID: String?,
        tabWorkspaceID: String?,
        targetWorkspaceID: String,
        hasWorkspaceType: Bool,
        hasTabType: Bool
    ) -> Action? {
        if hasTabType, draggedTabID != nil,
           let tabWorkspaceID, tabWorkspaceID != targetWorkspaceID {
            return .moveTabToWorkspace(
                workspaceID: targetWorkspaceID,
                insertBeforeTabID: nil
            )
        }
        guard hasWorkspaceType,
              let src = draggedWorkspaceID,
              src != targetWorkspaceID else {
            return nil
        }
        return .reorder
    }
}

// Reorders a sidebar row onto `targetID`. Reads the dragged id from the model
// synchronously (like PaneDropDelegate) rather than round-tripping through
// NSItemProvider's async load, and drives the drop-target highlight.
//
// It also handles pane drops. Rows preview their tab before the pane becomes
// a new tab. Both roles stay in one delegate because macOS uses one destination.
private struct SidebarReorderDropDelegate: DropDelegate {
    let targetID: String
    let type: UTType
    @ObservedObject var model: RaiModel
    @Binding var targeted: Bool
    var onPaneDragHover: (() -> Void)?
    var paneDropWorkspaceID: String?
    var paneInsertBeforeTabID: String?

    private func isPaneDrag(_ info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.raiPane.identifier])
    }

    // Headers handle two payloads: workspace reorders and tab relocations.
    private var handledTypeIdentifiers: [String] {
        type == .raiTab
            ? [UTType.raiTab.identifier]
            : [UTType.raiWorkspace.identifier, UTType.raiTab.identifier]
    }

    private func draggedTabWorkspaceID(_ tabs: [HerdrTab]?) -> String? {
        tabs?.first { $0.tabID == model.draggedTabID }?.workspaceID
    }

    private func action(_ info: DropInfo) -> SidebarDropRules.Action? {
        if isPaneDrag(info) {
            return SidebarDropRules.paneAction(
                draggedPaneID: model.draggedPaneID,
                targetWorkspaceID: paneDropWorkspaceID,
                insertBeforeTabID: paneInsertBeforeTabID
            )
        }
        let hasTabType = info.hasItemsConforming(to: [UTType.raiTab.identifier])
        let tabs = model.snapshot?.tabs
        if type == .raiTab {
            return SidebarDropRules.tabRowAction(
                draggedTabID: model.draggedTabID,
                targetTabID: targetID,
                hasTabType: hasTabType,
                sourceWorkspaceID: draggedTabWorkspaceID(tabs),
                targetWorkspaceID: tabs?.first { $0.tabID == targetID }?.workspaceID
            )
        }
        return SidebarDropRules.headerAction(
            draggedWorkspaceID: model.draggedWorkspaceID,
            draggedTabID: model.draggedTabID,
            tabWorkspaceID: draggedTabWorkspaceID(tabs),
            targetWorkspaceID: targetID,
            hasWorkspaceType: info.hasItemsConforming(
                to: [UTType.raiWorkspace.identifier]
            ),
            hasTabType: hasTabType
        )
    }

    func validateDrop(info: DropInfo) -> Bool {
        SidebarDropRules.acceptsSession(
            paneDrag: isPaneDrag(info),
            hasReorderType: info.hasItemsConforming(to: handledTypeIdentifiers),
            supportsPaneDrop: paneDropWorkspaceID != nil
        )
    }

    func dropEntered(info: DropInfo) {
        if isPaneDrag(info) {
            onPaneDragHover?()
        }
        targeted = action(info) != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let ok = action(info) != nil
        targeted = ok
        return DropProposal(operation: ok ? .move : .cancel)
    }

    func dropExited(info: DropInfo) {
        targeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            targeted = false
            model.draggedTabID = nil
            model.draggedWorkspaceID = nil
            model.draggedPaneID = nil
        }
        guard let action = action(info) else { return false }
        switch action {
        case .reorder:
            if type == .raiTab, let src = model.draggedTabID {
                model.moveTab(sourceTabID: src, onto: targetID)
            } else if let src = model.draggedWorkspaceID {
                model.moveWorkspace(sourceWorkspaceID: src, onto: targetID)
            }
        case let .moveTabToWorkspace(workspaceID, insertBeforeTabID):
            guard let src = model.draggedTabID else { return false }
            model.moveTab(
                src,
                toWorkspaceID: workspaceID,
                insertBeforeTabID: insertBeforeTabID
            )
        case let .movePaneToNewTab(workspaceID, insertBeforeTabID):
            guard let paneID = model.draggedPaneID else { return false }
            model.movePaneToNewTab(
                paneID,
                toWorkspaceID: workspaceID,
                insertBeforeTabID: insertBeforeTabID
            )
        }
        return true
    }
}

/// The sidebar's agents panel: every agent pane in the herd, flat, ordered by
/// who needs you (or by herd order). Mirrors herdr's own agents section.
private struct AgentPanelSection: View {
    @ObservedObject var model: RaiModel
    let listHeight: CGFloat
    let onDrag: (CGFloat) -> Void

    static let headerHeight: CGFloat = 30
    static let minimumListHeight: CGFloat = 44

    @State private var dividerHovering = false

    var body: some View {
        VStack(spacing: 0) {
            divider
            header
            if !model.agentPanelCollapsed {
                list.frame(height: listHeight)
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(dividerHovering ? Theme.accent.opacity(0.5) : Theme.hairline)
            .frame(height: 1)
            // A 1pt line is not a hit target — pad the grab area without moving
            // anything, so the divider stays visually hairline-thin.
            .overlay {
                Rectangle()
                    .fill(.clear)
                    .frame(height: 9)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        dividerHovering = hovering && !model.agentPanelCollapsed
                        guard !model.agentPanelCollapsed else { return }
                        if hovering {
                            NSCursor.resizeUpDown.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(coordinateSpace: .global)
                            .onChanged { value in
                                guard !model.agentPanelCollapsed else { return }
                                onDrag(value.translation.height - lastDrag)
                                lastDrag = value.translation.height
                            }
                            .onEnded { _ in lastDrag = 0 }
                    )
            }
            .allowsHitTesting(!model.agentPanelCollapsed)
    }

    // DragGesture reports a cumulative translation; the split moves by the
    // delta since the last callback.
    @State private var lastDrag: CGFloat = 0

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.textTertiary)
                .rotationEffect(.degrees(model.agentPanelCollapsed ? 0 : 90))
                .frame(width: 12, height: 12)
            Text("AGENTS")
                .font(.system(size: 10.5, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(Theme.textSecondary)
            if model.agentPanelCollapsed, !model.agentPanelEntries.isEmpty {
                Text("\(model.agentPanelEntries.count)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 4)
            Button(action: model.toggleAgentPanelSort) {
                Text(model.agentPanelSort.label)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Theme.interactionWash(opacity: 0.05))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(
                model.agentPanelSort == .priority
                    ? "Sorted by who needs you — click for herd order"
                    : "Sorted in herd order — click for who needs you"
            )
        }
        .padding(.horizontal, 11)
        .frame(height: Self.headerHeight)
        .contentShape(Rectangle())
        // The header itself expands and collapses the panel; the sort button
        // above claims its own taps first.
        .onTapGesture { model.toggleAgentPanelCollapsed() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Agents")
    }

    @ViewBuilder
    private var list: some View {
        let entries = model.agentPanelEntries
        if entries.isEmpty {
            Text("No agents in this herd.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 12)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(entries) { entry in
                        AgentPanelRow(
                            model: model,
                            entry: entry,
                            selected: model.selectedPaneID == entry.paneID
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct AgentPanelRow: View {
    @ObservedObject var model: RaiModel
    let entry: AgentPanelEntry
    let selected: Bool

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(status: entry.status)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(entry.workspaceLabel)
                        .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    if let tabLabel = entry.tabLabel {
                        Text("·")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                        Text(tabLabel)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                if let agentLabel = entry.agentLabel {
                    Text(agentLabel)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.status(entry.status))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
        }
        .modifier(SidebarRowChrome(selected: selected, hovering: hovering))
        .onTapGesture { select() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { select() }
        .onHover { hovering = $0 }
        .help(helpText)
        .contextMenu {
            Button("Focus", action: select)
            Button("Close Pane", role: .destructive) {
                model.closePane(entry.paneID)
            }
        }
    }

    private var helpText: String {
        var parts = [entry.workspaceLabel]
        if let tabLabel = entry.tabLabel { parts.append(tabLabel) }
        if let agentLabel = entry.agentLabel { parts.append(agentLabel) }
        return parts.joined(separator: " · ") + " — " + Theme.statusLabel(entry.status)
    }

    private func select() {
        model.select(paneID: entry.paneID, focusInHerdr: true)
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


/// A transparent, click-through NSView whose only job is carrying an AppKit
/// tooltip that survives SwiftUI re-renders (see AgentRow).
private struct ToolTipBackground: NSViewRepresentable {
    let text: String

    final class ClickThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> ClickThroughView {
        let view = ClickThroughView()
        view.toolTip = text
        return view
    }

    func updateNSView(_ view: ClickThroughView, context: Context) {
        if view.toolTip != text { view.toolTip = text }
    }
}
