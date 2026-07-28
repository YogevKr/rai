import RaiCore
import SwiftUI

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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAgentLauncher = true } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(!connection.status.isConnected)
                    .accessibilityLabel("Launch agent")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if let sessionName = connection.sessionName {
                            Text("Session: \(sessionName)")
                        }
                        Text("Mac: \(connection.host)")
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
        guard case .tab = renameTarget else { return false }
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
        }
        renameTarget = nil
    }

    private func commitClose() {
        guard let target = closeTarget else { return }
        switch target {
        case let .pane(id, _): connection.closePane(paneID: id)
        case let .tab(id, _): connection.closeTab(tabID: id)
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
        List {
            let needsYou = needsYouAgents(in: snapshot)
            if !needsYou.isEmpty {
                Section {
                    ForEach(needsYou) { item in
                        NavigationLink(value: item.pane.paneID) {
                            NeedsYouRow(item: item)
                        }
                    }
                } header: {
                    HStack {
                        Text("Needs you")
                        Spacer()
                        Text("\(needsYou.count) need you")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                    }
                }
            }

            ForEach(snapshot.workspaces) { workspace in
                Section {
                    let tabs = snapshot.tabs.filter { $0.workspaceID == workspace.workspaceID }
                    ForEach(tabs) { tab in
                        TabGroup(
                            tab: tab,
                            panes: snapshot.panes.filter { $0.tabID == tab.tabID },
                            rename: beginRename,
                            close: { closeTarget = $0 }
                        )
                    }
                } header: {
                    HStack {
                        Text(workspace.label.isEmpty ? "Space \(workspace.number)" : workspace.label)
                        Spacer()
                        StatusPill(status: workspace.agentStatus)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await connection.refreshSnapshot() }
    }

    private func needsYouAgents(in snapshot: SessionSnapshot) -> [NeedsYouAgent] {
        let workspaces = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map { ($0.workspaceID, $0) })
        let tabs = Dictionary(uniqueKeysWithValues: snapshot.tabs.map { ($0.tabID, $0) })

        return snapshot.panes.compactMap { pane in
            guard pane.agentStatus == .blocked || pane.agentStatus == .done,
                  let workspace = workspaces[pane.workspaceID],
                  let tab = tabs[pane.tabID] else {
                return nil
            }
            return NeedsYouAgent(pane: pane, workspace: workspace, tab: tab)
        }
    }
}

private enum RenameTarget {
    case pane(String, String)
    case tab(String, String)

    var title: String {
        switch self {
        case .pane: "Rename Pane"
        case .tab: "Rename Tab"
        }
    }

    var currentLabel: String {
        switch self {
        case let .pane(_, label), let .tab(_, label): label
        }
    }
}

private enum CloseTarget {
    case pane(String, String)
    case tab(String, String)

    var title: String {
        switch self {
        case .pane: "Close Pane?"
        case .tab: "Close Tab?"
        }
    }

    var name: String {
        switch self {
        case let .pane(_, name), let .tab(_, name): name
        }
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

private struct NeedsYouRow: View {
    let item: NeedsYouAgent

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.pane.agent ?? item.pane.terminalTitleStripped ?? "Pane")
                    .font(.headline)
                Text("\(workspaceLabel) · \(tabLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            StatusPill(status: item.pane.agentStatus)
        }
        .padding(.vertical, 2)
    }

    private var workspaceLabel: String {
        item.workspace.label.isEmpty ? "Space \(item.workspace.number)" : item.workspace.label
    }

    private var tabLabel: String {
        item.tab.label.isEmpty ? "Tab \(item.tab.number)" : item.tab.label
    }
}

private struct TabGroup: View {
    let tab: HerdrTab
    let panes: [Pane]
    let rename: (RenameTarget) -> Void
    let close: (CloseTarget) -> Void

    private var label: String {
        tab.label.isEmpty ? "Tab \(tab.number)" : tab.label
    }

    var body: some View {
        DisclosureGroup {
            ForEach(panes) { pane in
                NavigationLink(value: pane.paneID) {
                    PaneRow(pane: pane)
                }
                .contextMenu {
                    Button("Rename", systemImage: "pencil") {
                        rename(.pane(pane.paneID, pane.terminalTitleStripped ?? pane.agent ?? ""))
                    }
                    Button("Close", systemImage: "xmark", role: .destructive) {
                        close(.pane(pane.paneID, pane.terminalTitleStripped ?? pane.agent ?? "pane"))
                    }
                }
            }
        } label: {
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
        }
    }
}

private struct PaneRow: View {
    let pane: Pane

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(pane.agent ?? pane.terminalTitleStripped ?? "Pane")
                    .font(.body)
                Text(pane.foregroundCWD ?? pane.cwd)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            StatusPill(status: pane.agentStatus)
        }
        .padding(.vertical, 2)
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

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(label)")
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
        case .idle: .secondary
        case .working: .blue
        case .blocked: .orange
        case .done: .green
        case .unknown: .secondary
        }
    }
}
