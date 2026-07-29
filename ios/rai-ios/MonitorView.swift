import RaiCore
import SwiftUI

/// Nightwatch palette: the Mac terminal's Dracula+ identity on the phone.
/// Status is ANSI-derived — green working, amber needs-you, gray quiet.
enum Night {
    static let ground = Color(red: 0x16 / 255, green: 0x17 / 255, blue: 0x1D / 255)
    static let row = Color(red: 0x1C / 255, green: 0x1D / 255, blue: 0x25 / 255)
    static let hotRow = Color(red: 0x24 / 255, green: 0x1F / 255, blue: 0x14 / 255)
    static let hotEdge = Color(red: 0x4A / 255, green: 0x3B / 255, blue: 0x1A / 255)
    static let text = Color(red: 0xE8 / 255, green: 0xE6 / 255, blue: 0xE3 / 255)
    static let dim = Color(red: 0x8A / 255, green: 0x8C / 255, blue: 0x98 / 255)
    static let faint = Color(red: 0x6A / 255, green: 0x6C / 255, blue: 0x78 / 255)
    static let amber = Color(red: 1.0, green: 0xCB / 255, blue: 0x6B / 255)
    static let green = Color(red: 0x69 / 255, green: 1.0, blue: 0x94 / 255)
    static let shellGreen = Color(red: 0x50 / 255, green: 0xFA / 255, blue: 0x7B / 255)
    static let repoBlue = Color(red: 0x82 / 255, green: 0xAA / 255, blue: 1.0)
    static let idleDot = Color(red: 0x4A / 255, green: 0x4C / 255, blue: 0x57 / 255)

    /// The repo is the "where" — the last path component, never /Users/….
    static func repoName(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }
}

struct MonitorView: View {
    @ObservedObject var appModel: AppModel
    // Observed directly: BridgeConnection is its own ObservableObject, and
    // observing only AppModel would miss status/snapshot updates entirely —
    // the view would sit on "Connecting…" while the connection is live.
    @ObservedObject var connection: BridgeConnection
    let forgetPairing: () -> Void
    @State private var path: [String] = []
    @State private var didAutoOpen = false
    @State private var showingAgentLauncher = false
    @State private var renameTarget: RenameTarget?
    @State private var renameLabel = ""
    @State private var closeTarget: CloseTarget?
    @State private var backgroundWorkTarget: BackgroundWorkTarget?
    @State private var filter: HerdFilter?

    var body: some View {
        AnyView(NavigationStack(path: $path) {
            Group {
                if let snapshot = connection.snapshot {
                    if connection.status.isConnected, snapshot.panes.isEmpty {
                        emptyHerdState
                    } else {
                        herdList(snapshot)
                    }
                } else {
                    snapshotlessState
                }
            }
            .navigationDestination(for: String.self) { paneID in
                if let pane = connection.snapshot?.panes.first(where: { $0.paneID == paneID }) {
                    PaneTerminalView(pane: pane, connection: connection)
                }
            }
            .onChange(of: connection.snapshot?.panes.map(\.paneID) ?? []) { _, panes in
                autoOpenIfRequested(panes: panes)
                openPendingPush(panes: panes)
            }
            .onChange(of: appModel.pendingOpenPaneID) { _, _ in
                openPendingPush(panes: connection.snapshot?.panes.map(\.paneID) ?? [])
            }
            .onAppear {
                autoOpenIfRequested(panes: connection.snapshot?.panes.map(\.paneID) ?? [])
                openPendingPush(panes: connection.snapshot?.panes.map(\.paneID) ?? [])
            }
            .navigationTitle("rai")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The logo replaces the text title (the title string stays for
                // VoiceOver and the back button label).
                ToolbarItem(placement: .principal) {
                    Image("LogoMark")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 26)
                        .accessibilityHidden(true)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAgentLauncher = true } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(!connection.status.isConnected)
                    .accessibilityLabel("Launch agent")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if connection.sessions.count > 1 {
                            // Named herds: pick which one the Mac (and this
                            // phone) watches.
                            Menu("Session: \(connection.sessionName ?? "…")") {
                                ForEach(connection.sessions, id: \.name) { session in
                                    Button {
                                        connection.switchSession(named: session.name)
                                    } label: {
                                        if session.isCurrent {
                                            Label(session.name, systemImage: "checkmark")
                                        } else if session.isRunning {
                                            Text(session.name)
                                        } else {
                                            Text("\(session.name) (stopped)")
                                        }
                                    }
                                    .disabled(session.isCurrent)
                                }
                            }
                        } else if let sessionName = connection.sessionName {
                            Text("Session: \(sessionName)")
                        }
                        Text("Mac: \(connection.host)")
                            .onAppear { connection.requestSessions() }
                        Text("App: v\(Self.appVersion) (\(Self.appBuild))")
                        Divider()
                        if connection.requiresRepair {
                            Button("Pair Again", action: forgetPairing)
                        } else {
                            Button("Reconnect") { connection.retryNow() }
                        }
                        Button("Forget Mac", role: .destructive, action: forgetPairing)
                    } label: {
                        ConnectionBadge(status: connection.status)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if case .failed = connection.status {
                    HStack {
                        Image(systemName: "wifi.exclamationmark")
                        Text(connection.status.label)
                            .lineLimit(1)
                        Spacer()
                        if connection.requiresRepair {
                            Button("Pair Again", action: forgetPairing)
                        } else {
                            Button("Reconnect") { connection.retryNow() }
                        }
                    }
                    .font(.footnote)
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                    .background(.bar)
                }
            }
            .alert("Pairing Rejected", isPresented: repairBinding) {
                Button("Pair Again", action: forgetPairing)
            } message: {
                Text(connection.status.label)
            }
        })
        .sheet(isPresented: $showingAgentLauncher) {
            AgentLauncherSheet(
                workspaces: connection.snapshot?.workspaces ?? []
            ) { workspaceID, agent, cwd in
                connection.launchAgent(workspaceID: workspaceID, agent: agent, cwd: cwd)
            }
        }
        .sheet(item: $backgroundWorkTarget) { target in
            BackgroundWorkSheet(target: target)
        }
        .alert(renameTarget?.title ?? "Rename", isPresented: renameBinding) {
            TextField("Name", text: $renameLabel)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") { commitRename() }
                .disabled(renameIsDisabled)
        }
        .confirmationDialog(
            closeTarget?.title ?? "Close?",
            isPresented: closeBinding,
            titleVisibility: .visible
        ) {
            Button("Close", role: .destructive) { commitClose() }
            Button("Cancel", role: .cancel) { closeTarget = nil }
        } message: {
            Text("This will stop the processes in \(closeTarget?.name ?? "this item").")
        }
        .alert("Action Failed", isPresented: actionErrorBinding) {
            Button("OK") { connection.clearActionError() }
        } message: {
            Text(connection.actionError ?? "")
        }
        .preferredColorScheme(.dark)
    }

    static let appVersion = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString"
    ) as? String ?? "?"
    static let appBuild = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleVersion"
    ) as? String ?? "?"

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )
    }

    private var actionErrorBinding: Binding<Bool> {
        Binding(
            get: { connection.actionError != nil },
            set: { if !$0 { connection.clearActionError() } }
        )
    }

    private var closeBinding: Binding<Bool> {
        Binding(
            get: { closeTarget != nil },
            set: { if !$0 { closeTarget = nil } }
        )
    }

    private var renameIsDisabled: Bool {
        guard renameTarget != nil else { return false }
        return renameLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func beginRename(_ target: RenameTarget) {
        renameLabel = target.currentLabel
        renameTarget = target
    }

    private func commitRename() {
        guard let target = renameTarget else { return }
        let label = renameLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        switch target {
        case let .pane(id, _): connection.renamePane(paneID: id, label: label)
        case let .tab(id, _): connection.renameTab(tabID: id, label: label)
        case let .workspace(id, _): connection.renameWorkspace(workspaceID: id, label: label)
        }
        renameTarget = nil
    }

    private func commitClose() {
        guard let target = closeTarget else { return }
        switch target {
        case let .pane(id, _): connection.closePane(paneID: id)
        case let .tab(id, _): connection.closeTab(tabID: id)
        case let .workspace(id, _): connection.closeWorkspace(workspaceID: id)
        }
        closeTarget = nil
    }

    private var repairBinding: Binding<Bool> {
        Binding(
            get: { connection.requiresRepair },
            set: { _ in }
        )
    }

    // Testing/automation affordance mirroring RAI_PAIR_URL: auto-open a pane's
    // terminal on first sight so end-to-end runs are deterministic. Never set in
    // normal use.
    private func autoOpenIfRequested(panes: [String]) {
        guard !didAutoOpen,
              let target = ProcessInfo.processInfo.environment["RAI_OPEN_PANE"],
              panes.contains(target)
        else { return }
        didAutoOpen = true
        path.append(target)
    }

    private func openPendingPush(panes: [String]) {
        guard let paneID = appModel.pendingOpenPaneID, panes.contains(paneID) else { return }
        if path.last != paneID {
            path.append(paneID)
        }
        appModel.pendingOpenPaneID = nil
    }

    @ViewBuilder
    private var snapshotlessState: some View {
        switch connection.status {
        case .connecting:
            VStack(spacing: 12) {
                ProgressView()
                Text("Connecting to \(connection.host)…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .connected:
            emptyHerdState
        case let .failed(reason):
            failureState(reason: reason)
        case .disconnected:
            ContentUnavailableView {
                Label("Disconnected", systemImage: "wifi.slash")
            } actions: {
                Button("Reconnect") { connection.retryNow() }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No agents running", systemImage: "rectangle.stack")
        } description: {
            Text("Your herd will appear here when agents start.")
        }
    }

    private var emptyHerdState: some View {
        ScrollView {
            emptyState
                .frame(maxWidth: .infinity)
                .padding(.top, 120)
        }
        .refreshable { await connection.refreshSnapshot() }
    }

    private func failureState(reason: String) -> some View {
        ContentUnavailableView {
            Label("Connection failed", systemImage: "wifi.exclamationmark")
        } description: {
            Text(reason)
        } actions: {
            if connection.requiresRepair {
                Button("Pair Again", action: forgetPairing)
            } else {
                Button("Reconnect") { connection.retryNow() }
            }
        }
    }

    private func herdList(_ snapshot: SessionSnapshot) -> some View {
        let needsYou = agents(in: snapshot) { $0 == .blocked || $0 == .done }
        let working = agents(in: snapshot) { $0 == .working }
        let quiet = max(0, snapshot.panes.count - needsYou.count - working.count)
        return List {
            Section {
            } header: {
                PulseLine(
                    needsYou: needsYou.filter { $0.pane.agentStatus == .blocked }.count,
                    finished: needsYou.filter { $0.pane.agentStatus == .done }.count,
                    working: working.count,
                    quiet: quiet,
                    filter: $filter
                )
            }
            .listRowInsets(EdgeInsets())
            if let filter {
                filteredSection(
                    filter,
                    snapshot: snapshot,
                    needsYou: needsYou,
                    working: working
                )
            } else {
            if !needsYou.isEmpty {
                Section {
                    ForEach(needsYou) { item in
                        NavigationLink(value: item.pane.paneID) {
                            NightAgentRow(
                                item: item,
                                backgroundWork: backgroundWork(for: item.pane),
                                approve: item.pane.agentStatus == .blocked
                                    ? { connection.sendInput([0x0D], to: item.pane.paneID) }
                                    : nil,
                                deny: item.pane.agentStatus == .blocked
                                    ? { connection.sendInput([0x1B], to: item.pane.paneID) }
                                    : nil
                            )
                        }
                        .listRowBackground(
                            item.pane.agentStatus == .blocked ? Night.hotRow : Night.row
                        )
                        .contextMenu { backgroundWorkButton(for: item.pane) }
                    }
                } header: {
                    let anyBlocked = needsYou.contains { $0.pane.agentStatus == .blocked }
                    NightSectionHeader(
                        title: anyBlocked ? "Needs you" : "Finished",
                        detail: "\(needsYou.count)",
                        hot: anyBlocked
                    )
                }
            }
            if !working.isEmpty {
                Section {
                    ForEach(working) { item in
                        NavigationLink(value: item.pane.paneID) {
                            NightAgentRow(
                                item: item,
                                backgroundWork: backgroundWork(for: item.pane)
                            )
                        }
                        .listRowBackground(Night.row)
                        .contextMenu { backgroundWorkButton(for: item.pane) }
                    }
                } header: {
                    NightSectionHeader(title: "Working", detail: "\(working.count)")
                }
            }

            ForEach(snapshot.workspaces) { workspace in
                Section {
                    let tabs = snapshot.tabs.filter { $0.workspaceID == workspace.workspaceID }
                    ForEach(tabs) { tab in
                        TabGroup(
                            tab: tab,
                            panes: snapshot.panes.filter { $0.tabID == tab.tabID },
                            backgroundWorkByPaneID: appModel.backgroundWorkByPaneID,
                            rename: beginRename,
                            close: { closeTarget = $0 },
                            showBackgroundWork: { backgroundWorkTarget = $0 }
                        )
                        .listRowBackground(Night.row)
                    }
                } header: {
                    HStack {
                        Text(workspace.label.isEmpty ? "Space \(workspace.number)" : workspace.label)
                            .font(.caption.monospaced().weight(.semibold))
                            .foregroundStyle(Night.faint)
                        Spacer()
                        StatusPill(status: workspace.agentStatus)
                    }
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button("Rename", systemImage: "pencil") {
                            beginRename(.workspace(workspace.workspaceID, workspace.label))
                        }
                        Button("Close", systemImage: "xmark", role: .destructive) {
                            closeTarget = .workspace(
                                workspace.workspaceID,
                                workspace.label.isEmpty ? "Space \(workspace.number)" : workspace.label
                            )
                        }
                    }
                }
            }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Night.ground)
        .refreshable { await connection.refreshSnapshot() }
    }

    private func backgroundWork(for pane: Pane) -> [String] {
        appModel.backgroundWorkByPaneID[pane.paneID] ?? []
    }

    @ViewBuilder
    private func backgroundWorkButton(for pane: Pane) -> some View {
        let summaries = backgroundWork(for: pane)
        if !summaries.isEmpty {
            Button("Background Work", systemImage: "hourglass") {
                backgroundWorkTarget = BackgroundWorkTarget(
                    paneName: pane.terminalTitleStripped ?? pane.agent ?? "Pane",
                    summaries: summaries
                )
            }
        }
    }

    private func agents(
        in snapshot: SessionSnapshot,
        requireAgent: Bool = true,
        where matches: (AgentStatus) -> Bool
    ) -> [NeedsYouAgent] {
        let workspaces = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map { ($0.workspaceID, $0) })
        let tabs = Dictionary(uniqueKeysWithValues: snapshot.tabs.map { ($0.tabID, $0) })

        return snapshot.panes.compactMap { pane in
            guard matches(pane.agentStatus),
                  !requireAgent || pane.agent != nil,
                  let workspace = workspaces[pane.workspaceID],
                  let tab = tabs[pane.tabID] else {
                return nil
            }
            return NeedsYouAgent(pane: pane, workspace: workspace, tab: tab)
        }
    }

    /// One flat section while a pulse-line filter is active.
    @ViewBuilder
    private func filteredSection(
        _ filter: HerdFilter,
        snapshot: SessionSnapshot,
        needsYou: [NeedsYouAgent],
        working: [NeedsYouAgent]
    ) -> some View {
        let items: [NeedsYouAgent] = {
            switch filter {
            case .needsYou: needsYou.filter { $0.pane.agentStatus == .blocked }
            case .finished: needsYou.filter { $0.pane.agentStatus == .done }
            case .working: working
            case .quiet: agents(in: snapshot, requireAgent: false) {
                $0 == .idle || $0 == .unknown
            }
            }
        }()
        Section {
            if items.isEmpty {
                Text("none right now")
                    .font(.caption.monospaced())
                    .foregroundStyle(Night.faint)
                    .listRowBackground(Night.row)
            } else {
                ForEach(items) { item in
                    NavigationLink(value: item.pane.paneID) {
                        NightAgentRow(
                            item: item,
                            backgroundWork: backgroundWork(for: item.pane),
                            approve: item.pane.agentStatus == .blocked
                                ? { connection.sendInput([0x0D], to: item.pane.paneID) }
                                : nil,
                            deny: item.pane.agentStatus == .blocked
                                ? { connection.sendInput([0x1B], to: item.pane.paneID) }
                                : nil
                        )
                    }
                    .listRowBackground(
                        item.pane.agentStatus == .blocked ? Night.hotRow : Night.row
                    )
                    .contextMenu { backgroundWorkButton(for: item.pane) }
                }
            }
        } header: {
            NightSectionHeader(
                title: filter.title,
                detail: "\(items.count)",
                hot: filter == .needsYou
            )
        }
    }
}

enum HerdFilter {
    case needsYou, finished, working, quiet

    var title: String {
        switch self {
        case .needsYou: "Needs you"
        case .finished: "Finished"
        case .working: "Working"
        case .quiet: "Quiet"
        }
    }
}

private enum RenameTarget {
    case pane(String, String)
    case tab(String, String)
    case workspace(String, String)

    var title: String {
        switch self {
        case .pane: "Rename Pane"
        case .tab: "Rename Tab"
        case .workspace: "Rename Workspace"
        }
    }

    var currentLabel: String {
        switch self {
        case let .pane(_, label), let .tab(_, label), let .workspace(_, label): label
        }
    }
}

private enum CloseTarget {
    case pane(String, String)
    case tab(String, String)
    case workspace(String, String)

    var title: String {
        switch self {
        case .pane: "Close Pane?"
        case .tab: "Close Tab?"
        case .workspace: "Close Workspace?"
        }
    }

    var name: String {
        switch self {
        case let .pane(_, name), let .tab(_, name), let .workspace(_, name): name
        }
    }
}

private struct BackgroundWorkTarget: Identifiable {
    let id = UUID()
    let paneName: String
    let summaries: [String]
}

private struct BackgroundWorkSheet: View {
    let target: BackgroundWorkTarget
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section(target.paneName) {
                    ForEach(Array(target.summaries.enumerated()), id: \.offset) { _, summary in
                        Label(summary, systemImage: "hourglass")
                    }
                }
            }
            .navigationTitle("Background Work")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct AgentLauncherSheet: View {
    let workspaces: [Workspace]
    let launch: (String?, String, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var agent = "claude"
    @State private var workspaceID: String?
    @State private var directory = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("Agent", selection: $agent) {
                    Text("Claude").tag("claude")
                    Text("Codex").tag("codex")
                    Text("Terminal").tag("terminal")
                }
                .pickerStyle(.segmented)

                Picker("Workspace", selection: $workspaceID) {
                    Text("New workspace").tag(String?.none)
                    ForEach(workspaces) { workspace in
                        Text(workspace.label.isEmpty
                            ? "Space \(workspace.number)"
                            : workspace.label
                        )
                        .tag(Optional(workspace.workspaceID))
                    }
                }

                // Agents into an existing workspace inherit its directory
                // (matches the Mac launcher); a fresh workspace — or a plain
                // terminal anywhere — can start where you point it.
                if workspaceID == nil || agent == "terminal" {
                    TextField("Directory on Mac (optional)", text: $directory)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("Launch Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(agent == "terminal" ? "Open" : "Launch") {
                        let cwd = directory.trimmingCharacters(in: .whitespacesAndNewlines)
                        let cwdApplies = workspaceID == nil || agent == "terminal"
                        launch(
                            workspaceID,
                            agent,
                            cwdApplies && !cwd.isEmpty ? cwd : nil
                        )
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct NeedsYouAgent: Identifiable {
    let pane: Pane
    let workspace: Workspace
    let tab: HerdrTab

    var id: String { pane.paneID }
}

/// The herd in one glance — and the filter bar: tap a segment to see only
/// that state, tap it again to see everything.
private struct PulseLine: View {
    let needsYou: Int
    let finished: Int
    let working: Int
    let quiet: Int
    @Binding var filter: HerdFilter?

    var body: some View {
        HStack(spacing: 2) {
            if needsYou > 0 {
                segment("\(needsYou) needs you", .needsYou, Night.amber)
                sep
            }
            if finished > 0 {
                segment("\(finished) finished", .finished, Night.green)
                sep
            }
            segment("\(working) working", .working, Night.dim)
            sep
            segment("\(quiet) quiet", .quiet, Night.faint)
        }
        .font(.footnote.monospaced())
        .textCase(nil)
        .padding(.bottom, 2)
    }

    private var sep: some View {
        Text("·").foregroundStyle(Night.faint)
    }

    private func segment(_ label: String, _ target: HerdFilter, _ color: Color) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) {
                filter = filter == target ? nil : target
            }
        } label: {
            Text(label)
                .fontWeight(target == .needsYou ? .semibold : .regular)
                .foregroundStyle(
                    filter == nil || filter == target ? color : Night.faint.opacity(0.55)
                )
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    filter == target ? Color.white.opacity(0.09) : .clear,
                    in: Capsule()
                )
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("\(label)\(filter == target ? ", filtered" : "")")
        .accessibilityHint(filter == target ? "Shows everything" : "Shows only these")
    }
}

private struct NightSectionHeader: View {
    let title: String
    let detail: String
    var hot = false

    var body: some View {
        HStack {
            Text(title)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(hot ? Night.amber : Night.faint)
            Spacer()
            Text(detail)
                .font(.caption.monospaced())
                .foregroundStyle(Night.faint)
                .textCase(nil)
        }
    }
}

/// Task first, repo second, the live activity line third — the binary name
/// ("claude") never leads. Blocked panes grow inline Approve / Deny.
private struct NightAgentRow: View {
    let item: NeedsYouAgent
    let backgroundWork: [String]
    var approve: (() -> Void)?
    var deny: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                StatusGlowDot(status: item.pane.agentStatus)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Night.text)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        if let repo = Night.repoName(item.pane.foregroundCWD ?? item.pane.cwd) {
                            Text(repo)
                                .foregroundStyle(Night.repoBlue)
                        }
                        Text("· \(statusWord)")
                            .foregroundStyle(Night.faint)
                    }
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    if let activity {
                        (Text("❯ ").foregroundStyle(Night.shellGreen)
                            + Text(activity).foregroundStyle(Night.faint))
                            .font(.caption.monospaced())
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if backgroundWork.count > 0 {
                    Text("⏳ \(backgroundWork.count)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Night.amber)
                }
            }
            if approve != nil || deny != nil {
                HStack(spacing: 8) {
                    if let approve {
                        Button(action: approve) {
                            Text("Approve")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(Night.amber, in: RoundedRectangle(cornerRadius: 7))
                                .foregroundStyle(Night.hotRow)
                        }
                        .buttonStyle(.borderless)
                    }
                    if let deny {
                        Button(action: deny) {
                            Text("Deny")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                                .foregroundStyle(Night.text)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.leading, 17)
            }
        }
        .padding(.vertical, 4)
    }

    /// The task name: the tab's label (herdr names tabs after the task),
    /// falling back to the terminal title, only then the agent binary.
    private var title: String {
        if !item.tab.label.isEmpty { return item.tab.label }
        return item.pane.terminalTitleStripped ?? item.pane.agent ?? "Pane"
    }

    /// The terminal title doubles as the live activity when it says something
    /// beyond the row title (Claude keeps it set to the current step).
    private var activity: String? {
        guard let stripped = item.pane.terminalTitleStripped, !stripped.isEmpty
        else { return nil }
        // The title is often the same text — or herdr's own "…"-truncated
        // copy of it. Strip the ellipsis before comparing, or the line just
        // repeats the row title.
        var head = title
        if head.hasSuffix("…") { head.removeLast() }
        if head.hasSuffix("...") { head.removeLast(3) }
        if stripped.hasPrefix(head) || head.hasPrefix(stripped) { return nil }
        return stripped
    }

    private var statusWord: String {
        switch item.pane.agentStatus {
        case .blocked: "waiting on you"
        case .done: "finished"
        case .working: "working"
        case .idle: "idle"
        case .unknown: "—"
        }
    }
}

private struct StatusGlowDot: View {
    let status: AgentStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .shadow(color: glow, radius: 4)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch status {
        case .working: Night.green
        case .blocked: Night.amber
        case .done: Night.green
        case .idle, .unknown: Night.idleDot
        }
    }

    private var glow: Color {
        switch status {
        case .working: Night.green.opacity(0.55)
        case .blocked: Night.amber.opacity(0.6)
        case .done: Night.green.opacity(0.35)
        case .idle, .unknown: .clear
        }
    }
}

private struct TabGroup: View {
    let tab: HerdrTab
    let panes: [Pane]
    let backgroundWorkByPaneID: [String: [String]]
    let rename: (RenameTarget) -> Void
    let close: (CloseTarget) -> Void
    let showBackgroundWork: (BackgroundWorkTarget) -> Void

    private var label: String {
        tab.label.isEmpty ? "Tab \(tab.number)" : tab.label
    }

    var body: some View {
        // A tab is almost always a single pane on a phone — flatten it to one
        // tappable row named after the tab. Only real splits get a header row
        // with their panes beneath; nothing collapses.
        if panes.count == 1, let pane = panes.first {
            NavigationLink(value: pane.paneID) {
                HStack(spacing: 10) {
                    StatusGlowDot(status: pane.agentStatus)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tab.label.isEmpty
                            ? (pane.terminalTitleStripped ?? pane.agent ?? "Tab \(tab.number)")
                            : tab.label
                        )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Night.text)
                        .lineLimit(1)
                        Text(Night.repoName(pane.foregroundCWD ?? pane.cwd) ?? "")
                            .font(.caption.monospaced())
                            .foregroundStyle(Night.repoBlue)
                            .lineLimit(1)
                    }
                    Spacer()
                    PaneStatus(
                        status: pane.agentStatus,
                        backgroundWorkCount: backgroundWork(for: pane).count
                    )
                }
                .padding(.vertical, 2)
            }
            .contextMenu {
                backgroundWorkButton(for: pane)
                Button("Rename", systemImage: "pencil") {
                    rename(.tab(tab.tabID, tab.label))
                }
                Button("Close", systemImage: "xmark", role: .destructive) {
                    close(.tab(tab.tabID, label))
                }
            }
        } else {
            HStack(spacing: 12) {
                Image(systemName: tab.focused ? "rectangle.fill" : "rectangle")
                    .foregroundStyle(.secondary)
                Text(label)
                    .font(.headline)
                Spacer()
                StatusPill(status: tab.agentStatus)
            }
            .padding(.vertical, 4)
            .contextMenu {
                Button("Rename", systemImage: "pencil") {
                    rename(.tab(tab.tabID, tab.label))
                }
                Button("Close", systemImage: "xmark", role: .destructive) {
                    close(.tab(tab.tabID, label))
                }
            }
            ForEach(panes) { pane in
                NavigationLink(value: pane.paneID) {
                    PaneRow(pane: pane, backgroundWork: backgroundWork(for: pane))
                        .padding(.leading, 16)
                }
                .contextMenu {
                    backgroundWorkButton(for: pane)
                    Button("Rename", systemImage: "pencil") {
                        rename(.pane(pane.paneID, pane.terminalTitleStripped ?? pane.agent ?? ""))
                    }
                    Button("Close", systemImage: "xmark", role: .destructive) {
                        close(.pane(pane.paneID, pane.terminalTitleStripped ?? pane.agent ?? "pane"))
                    }
                }
            }
        }
    }

    private func backgroundWork(for pane: Pane) -> [String] {
        backgroundWorkByPaneID[pane.paneID] ?? []
    }

    @ViewBuilder
    private func backgroundWorkButton(for pane: Pane) -> some View {
        let summaries = backgroundWork(for: pane)
        if !summaries.isEmpty {
            Button("Background Work", systemImage: "hourglass") {
                showBackgroundWork(
                    BackgroundWorkTarget(
                        paneName: pane.terminalTitleStripped ?? pane.agent ?? "Pane",
                        summaries: summaries
                    )
                )
            }
        }
    }
}

private struct PaneRow: View {
    let pane: Pane
    let backgroundWork: [String]

    var body: some View {
        HStack(spacing: 10) {
            StatusGlowDot(status: pane.agentStatus)
            VStack(alignment: .leading, spacing: 3) {
                Text(pane.terminalTitleStripped ?? pane.agent ?? "Pane")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Night.text)
                    .lineLimit(1)
                Text(Night.repoName(pane.foregroundCWD ?? pane.cwd) ?? "")
                    .font(.caption.monospaced())
                    .foregroundStyle(Night.repoBlue)
                    .lineLimit(1)
            }
            Spacer()
            PaneStatus(status: pane.agentStatus, backgroundWorkCount: backgroundWork.count)
        }
        .padding(.vertical, 2)
    }
}

private struct PaneStatus: View {
    let status: AgentStatus
    let backgroundWorkCount: Int

    var body: some View {
        HStack(spacing: 8) {
            if backgroundWorkCount > 0 {
                Text("⏳ \(backgroundWorkCount)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.orange)
                    .accessibilityLabel("\(backgroundWorkCount) background work items")
            }
            StatusPill(
                status: status,
                labelOverride: status == .idle && backgroundWorkCount > 0 ? "Waiting" : nil
            )
        }
    }
}

private struct ConnectionBadge: View {
    let status: BridgeConnection.Status

    var body: some View {
        Label(status.label, systemImage: symbol)
            .labelStyle(.iconOnly)
            .foregroundStyle(color)
            .accessibilityLabel(status.label)
    }

    private var symbol: String {
        switch status {
        case .disconnected: "wifi.slash"
        case .connecting: "wifi"
        case .connected: "wifi"
        case .failed: "wifi.exclamationmark"
        }
    }

    private var color: Color {
        switch status {
        case .disconnected: .secondary
        case .connecting: .orange
        case .connected: .green
        case .failed: .red
        }
    }
}

private struct StatusPill: View {
    let status: AgentStatus
    var labelOverride: String?

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(labelOverride ?? label)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(labelOverride ?? label)")
    }

    private var label: String {
        switch status {
        case .idle: "Idle"
        case .working: "Working"
        case .blocked: "Needs you"
        case .done: "Done"
        case .unknown: "Unknown"
        }
    }

    private var color: Color {
        switch status {
        case .idle: Night.dim
        case .working: Night.green
        case .blocked: Night.amber
        case .done: Night.green
        case .unknown: Night.dim
        }
    }
}
