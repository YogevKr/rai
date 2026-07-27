import RaiCore
import Foundation
import SwiftUI

@MainActor
protocol RaiSnapshotObserver: AnyObject {
    func raiModel(
        _ model: RaiModel,
        didRefresh snapshot: SessionSnapshot,
        transitions: [PaneStatusTransition]
    )
}

enum AgentLaunchKind: String {
    case claude
    case codex
}

struct ClosedTabRecord: Equatable {
    let workspaceID: String
    let cwd: String
    let agentKind: AgentLaunchKind?
    let label: String
}

struct PaneProcessInfo: Decodable, Equatable, Sendable {
    struct ForegroundProcess: Decodable, Equatable, Sendable {
        let pid: Int
        let name: String
        let argv0: String
        let argv: [String]
        let cmdline: String
        let cwd: String
    }

    let paneID: String
    let shellPID: Int
    // tty is absent for herdr attach panes; the group id is nullable per schema.
    let tty: String?
    let foregroundProcessGroupID: Int?
    let foregroundProcesses: [ForegroundProcess]

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case shellPID = "shell_pid"
        case tty
        case foregroundProcessGroupID = "foreground_process_group_id"
        case foregroundProcesses = "foreground_processes"
    }
}

private struct PaneProcessInfoResponse: Decodable {
    struct Result: Decodable {
        let processInfo: PaneProcessInfo

        enum CodingKeys: String, CodingKey {
            case processInfo = "process_info"
        }
    }

    let result: Result
}

private struct PluginActionListResponse: Decodable {
    struct Result: Decodable {
        let actions: [Action]
    }

    struct Action: Decodable {
        let actionID: String
        let title: String
        let description: String?
        let pluginID: String
        let contexts: Set<PluginAction.Context>
        let platforms: [String]

        enum CodingKeys: String, CodingKey {
            case actionID = "action_id"
            case title
            case description
            case pluginID = "plugin_id"
            case contexts
            case platforms
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            actionID = try container.decode(String.self, forKey: .actionID)
            title = try container.decode(String.self, forKey: .title)
            description = try container.decodeIfPresent(String.self, forKey: .description)
            pluginID = try container.decode(String.self, forKey: .pluginID)
            contexts = try container.decodeIfPresent(
                Set<PluginAction.Context>.self,
                forKey: .contexts
            ) ?? []
            platforms = try container.decode([String].self, forKey: .platforms)
        }

        var pluginAction: PluginAction {
            PluginAction(
                id: actionID,
                title: title,
                description: description,
                pluginId: pluginID,
                contexts: contexts
            )
        }
    }

    let result: Result
}

// `plugin action invoke` returns immediately with a log_id; the action runs
// async and its stdout/stderr land in the plugin log, fetched separately.
private struct PluginActionInvokeResponse: Decodable {
    struct Result: Decodable { let log: LogRef? }
    struct LogRef: Decodable {
        let logID: String
        enum CodingKeys: String, CodingKey { case logID = "log_id" }
    }
    let result: Result
}

private struct PluginLogListResponse: Decodable {
    struct Result: Decodable { let logs: [Entry] }
    struct Entry: Decodable {
        let logID: String
        let status: String
        let exitCode: Int?
        let stdout: String
        let stderr: String
        enum CodingKeys: String, CodingKey {
            case logID = "log_id"
            case status
            case exitCode = "exit_code"
            case stdout
            case stderr
        }
    }
    let result: Result
}

@MainActor
final class RaiModel: ObservableObject {
    enum ConnectionState: Equatable {
        case connecting
        case connected(version: String, protocolVersion: Int)
        case disconnected(String)
    }

    @Published private(set) var snapshot: SessionSnapshot?
    @Published private(set) var connectionState: ConnectionState = .connecting
    @Published var selectedPaneID: String?
    @Published var draggedPaneID: String?
    // Sidebar reorder drag state (mirrors draggedPaneID) — read synchronously by
    // the drop delegates rather than round-tripping through NSItemProvider.
    @Published var draggedTabID: String?
    @Published var draggedWorkspaceID: String?
    @Published var onlyNeedsYou = false
    // Spaces the user has collapsed in the sidebar. A collapsed space hides its
    // tabs except the ones that need attention (and the selected one).
    @Published var collapsedWorkspaceIDs: Set<String> = []
    @Published var notificationsMuted: Bool {
        didSet {
            userDefaults.set(
                notificationsMuted,
                forKey: Self.notificationsMutedDefaultsKey
            )
        }
    }
    @Published var isCommandPalettePresented = false
    @Published var isBroadcastPresented = false
    @Published var paletteQuery = ""
    @Published var paletteSelectedID: String?
    @Published var renameRequest: RenameRequest?
    // In-place sidebar rename: which tab/space is currently editing its name.
    @Published var inlineRename: InlineRenameTarget?
    @Published var workspacePendingClose: Workspace?
    @Published var statusExplanation: StatusExplanation?
    @Published var pluginActions: [PluginAction] = []
    @Published var worktreeCreateRequest: WorktreeCreateRequest?
    @Published var worktreeOpenRequest: WorktreeOpenRequest?
    @Published var worktreeAlert: WorktreeAlert?
    @Published private(set) var sessions: [HerdrSession] = []
    @Published private(set) var activeSocketPath: String
    @Published private(set) var currentSessionName: String
    @Published private(set) var remoteTarget: String?
    @Published private(set) var closedTabs: [ClosedTabRecord] = []
    @Published var newSessionRequest: NewSessionRequest?
    @Published var remoteHerdRequest: RemoteHerdRequest?
    @Published var sessionAlert: SessionAlert?
    // Live split ratio while a divider is being dragged (split id → ratio),
    // for smooth local feedback; cleared once herdr's snapshot reflects the commit.
    @Published var dragRatios: [String: Double] = [:]

    private(set) var client: HerdrClient
    let terminalPool: TerminalPool
    lazy var bridgeServer = RaiBridgeServer(model: self, userDefaults: userDefaults)

    weak var snapshotObserver: RaiSnapshotObserver?

    private static let notificationsMutedDefaultsKey = "notificationsMuted"
    private let userDefaults: UserDefaults
    private var started = false
    private var eventTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var pendingEvents: [HerdrEvent] = []
    private var lastObservedPaneStatuses: [String: AgentStatus]?
    private var connectionGeneration = UUID()
    private var connectionAttemptID = UUID()
    private var remoteConnection: RemoteConnection?
    private var launchedSessionServers: [String: Process] = [:]

    init(
        client: HerdrClient = HerdrClient(),
        userDefaults: UserDefaults = .standard
    ) {
        self.client = client
        activeSocketPath = client.socketPath
        currentSessionName = Self.inferredSessionName(for: client.socketPath)
        terminalPool = TerminalPool(socketPath: client.socketPath)
        self.userDefaults = userDefaults
        notificationsMuted = userDefaults.bool(
            forKey: Self.notificationsMutedDefaultsKey
        )
    }

    deinit {
        eventTask?.cancel()
        flushTask?.cancel()
        client.disconnect()
    }

    var currentSessionDisplayName: String {
        if let remoteTarget {
            return "\(currentSessionName) @ \(remoteTarget)"
        }
        return currentSessionName
    }

    var selectedPane: Pane? {
        snapshot?.panes.first { $0.paneID == selectedPaneID }
    }

    var blockedAgentCount: Int {
        snapshot?.panes.lazy.filter { $0.agentStatus == .blocked }.count ?? 0
    }

    var selectedTabID: String? {
        selectedPane?.tabID
    }

    var selectedTab: HerdrTab? {
        snapshot?.tabs.first { $0.tabID == selectedTabID }
    }

    var canReopenClosedTab: Bool {
        !closedTabs.isEmpty
    }

    func isWorkspaceCollapsed(_ workspaceID: String) -> Bool {
        collapsedWorkspaceIDs.contains(workspaceID)
    }

    func toggleWorkspaceCollapsed(_ workspaceID: String) {
        if collapsedWorkspaceIDs.contains(workspaceID) {
            collapsedWorkspaceIDs.remove(workspaceID)
        } else {
            collapsedWorkspaceIDs.insert(workspaceID)
        }
    }

    var selectedWorkspace: Workspace? {
        guard let workspaceID = selectedPane?.workspaceID else { return nil }
        return snapshot?.workspaces.first { $0.workspaceID == workspaceID }
    }

    var selectedWorkspaceTabs: [HerdrTab] {
        guard let workspaceID = selectedWorkspace?.workspaceID else { return [] }
        return snapshot?.tabs
            .filter { $0.workspaceID == workspaceID }
 ?? []
    }

    var selectedLayout: PaneLayoutSnapshot? {
        guard let selectedTabID else { return nil }
        return snapshot?.layouts.first { $0.tabID == selectedTabID }
    }

    var visiblePanes: [Pane] {
        guard let snapshot, let selectedTabID else { return [] }
        let panes = snapshot.panes.filter { $0.tabID == selectedTabID }
        guard let layout = selectedLayout else { return panes }
        let order = Dictionary(
            uniqueKeysWithValues: layout.panes.enumerated().map { ($1.paneID, $0) }
        )
        return panes.sorted {
            order[$0.paneID, default: .max] < order[$1.paneID, default: .max]
        }
    }

    func displayTitle(for pane: Pane) -> String {
        if let title = pane.terminalTitleStripped?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        if let agent = pane.agent?.trimmingCharacters(in: .whitespacesAndNewlines),
           !agent.isEmpty {
            return agent
        }
        if let label = snapshot?.tabs.first(where: { $0.tabID == pane.tabID })?
            .label.trimmingCharacters(in: .whitespacesAndNewlines),
           !label.isEmpty,
           Int(label) == nil {
            return label
        }
        return "Terminal"
    }

    var commandPaletteItems: [CommandPaletteItem] {
        guard let snapshot else { return [] }
        var items: [CommandPaletteItem] = []
        for workspace in snapshot.workspaces {
            let workspaceLabel = workspace.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayWorkspaceLabel = workspaceLabel.isEmpty
                ? "Space \(workspace.number)"
                : workspaceLabel
            items.append(
                CommandPaletteItem(
                    id: "workspace:\(workspace.workspaceID)",
                    label: displayWorkspaceLabel,
                    workspaceLabel: displayWorkspaceLabel,
                    status: workspace.agentStatus,
                    destination: .workspace(workspace.workspaceID),
                    isWorkspace: true
                )
            )

            let tabs = snapshot.tabs
                .filter { $0.workspaceID == workspace.workspaceID }
                            items.append(
                contentsOf: tabs.map { tab in
                    CommandPaletteItem(
                        id: "tab:\(tab.tabID)",
                        label: snapshot.displayLabel(for: tab),
                        workspaceLabel: displayWorkspaceLabel,
                        status: tab.agentStatus,
                        destination: .tab(tab.tabID),
                        isWorkspace: false
                    )
                }
            )
        }
        return items
    }

    func start() {
        guard !started else { return }
        started = true
        bridgeServer.startIfEnabled()
        let attemptID = UUID()
        connectionAttemptID = attemptID

        Task {
            guard attemptID == connectionAttemptID else { return }
            await connect(
                toSocket: activeSocketPath,
                sessionName: currentSessionName,
                remote: nil
            )
            await reloadSessions()
        }
    }

    func shutdown() async {
        await bridgeServer.stopAndWait()
        tearDownCurrentConnection(stopRemote: true)
    }

    // MARK: - Herd sessions

    /// Switches the complete herd-scoped runtime to a fresh client.
    func connect(toSocket socketPath: String) {
        let attemptID = UUID()
        connectionAttemptID = attemptID
        Task {
            guard attemptID == connectionAttemptID else { return }
            await connect(
                toSocket: socketPath,
                sessionName: Self.inferredSessionName(for: socketPath),
                remote: nil
            )
        }
    }

    func switchSession(_ session: HerdrSession) {
        let attemptID = UUID()
        connectionAttemptID = attemptID
        Task {
            if session.isRunning {
                guard attemptID == connectionAttemptID else { return }
                await connect(
                    toSocket: session.socketPath,
                    sessionName: session.name,
                    remote: nil
                )
                await reloadSessions()
            } else {
                await startSession(
                    named: session.name,
                    requireNew: false,
                    attemptID: attemptID
                )
            }
        }
    }

    func refreshSessions() {
        Task { await reloadSessions() }
    }

    func beginCreateSession() {
        newSessionRequest = NewSessionRequest()
    }

    func createSession(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidSessionName(name) else {
            sessionAlert = SessionAlert(
                kind: .error(
                    title: "Invalid Session Name",
                    message: "Use letters, numbers, periods, underscores, or hyphens."
                )
            )
            return
        }
        newSessionRequest = nil
        let attemptID = UUID()
        connectionAttemptID = attemptID
        Task {
            await startSession(
                named: name,
                requireNew: true,
                attemptID: attemptID
            )
        }
    }

    func requestStopSession(_ session: HerdrSession) {
        sessionAlert = SessionAlert(
            kind: .confirmStop(session, isCurrent: isViewing(session))
        )
    }

    func isCurrentSession(_ session: HerdrSession) -> Bool {
        isViewing(session)
    }

    func confirmStopSession(_ session: HerdrSession) {
        sessionAlert = nil
        Task {
            let wasCurrent = isViewing(session)
            let result = await runHerdrResult(
                ["session", "stop", session.name],
                usesActiveSocket: false
            )
            guard result.succeeded else {
                showSessionError(
                    title: "Couldn’t Stop Session",
                    output: result.errorOutput
                )
                return
            }
            if wasCurrent {
                disconnectCurrentHerd(
                    message: "Session “\(session.name)” was stopped."
                )
            }
            await reloadSessions()
        }
    }

    func beginRemoteConnection() {
        remoteHerdRequest = RemoteHerdRequest()
    }

    func connectRemote(target: String, sessionName: String) {
        remoteHerdRequest = nil
        let attemptID = UUID()
        connectionAttemptID = attemptID
        Task {
            do {
                let discovered = try await RemoteConnection.discoverSocket(
                    target: target,
                    sessionName: sessionName
                )
                guard attemptID == connectionAttemptID else { return }
                let tunnel = RemoteConnection(
                    target: discovered.target,
                    sessionName: discovered.sessionName,
                    remoteSocketPath: discovered.socketPath
                )
                tunnel.onUnexpectedExit = { [weak self] id, message in
                    self?.remoteTunnelDidExit(
                        id: id,
                        attemptID: attemptID,
                        message: message
                    )
                }
                try await tunnel.start()
                guard attemptID == connectionAttemptID else {
                    tunnel.stop()
                    return
                }
                await connect(
                    toSocket: tunnel.localSocketPath,
                    sessionName: tunnel.sessionName,
                    remote: tunnel
                )
            } catch {
                if snapshot == nil {
                    connectionState = .disconnected(error.localizedDescription)
                }
                sessionAlert = SessionAlert(
                    kind: .error(
                        title: "Couldn’t Connect to Remote Herd",
                        message: error.localizedDescription
                    )
                )
            }
        }
    }

    func disconnectRemote() {
        guard remoteConnection != nil else { return }
        connectionAttemptID = UUID()
        disconnectCurrentHerd(message: "Disconnected from \(currentSessionDisplayName).")
    }

    private func connect(
        toSocket rawSocketPath: String,
        sessionName: String,
        remote: RemoteConnection?
    ) async {
        let socketPath = NSString(string: rawSocketPath).expandingTildeInPath
        tearDownCurrentConnection(stopRemote: true)

        let generation = UUID()
        connectionGeneration = generation
        activeSocketPath = socketPath
        currentSessionName = sessionName
        remoteTarget = remote?.target
        remoteConnection = remote
        client = HerdrClient(socketPath: socketPath)
        terminalPool.switchSocket(to: socketPath)
        connectionState = .connecting

        await refreshSnapshot(
            keepSelection: false,
            client: client,
            generation: generation
        )
        guard generation == connectionGeneration else { return }
        startEventLoop(client: client, generation: generation)
    }

    private func disconnectCurrentHerd(message: String) {
        connectionAttemptID = UUID()
        tearDownCurrentConnection(stopRemote: true)
        connectionGeneration = UUID()
        snapshot = nil
        selectedPaneID = nil
        lastObservedPaneStatuses = nil
        connectionState = .disconnected(message)
    }

    private func tearDownCurrentConnection(stopRemote: Bool) {
        connectionGeneration = UUID()
        eventTask?.cancel()
        eventTask = nil
        flushTask?.cancel()
        flushTask = nil
        pendingEvents.removeAll(keepingCapacity: false)
        client.disconnect()
        terminalPool.removeAll()
        if stopRemote {
            remoteConnection?.stop()
            remoteConnection = nil
            remoteTarget = nil
        }
        snapshot = nil
        selectedPaneID = nil
        draggedPaneID = nil
        dragRatios.removeAll()
        lastObservedPaneStatuses = nil
        isCommandPalettePresented = false
        renameRequest = nil
        workspacePendingClose = nil
        statusExplanation = nil
        pluginActions = []
        worktreeCreateRequest = nil
        worktreeOpenRequest = nil
        worktreeAlert = nil
    }

    private func reloadSessions() async {
        let result = await runHerdrResult(
            ["session", "list", "--json"],
            usesActiveSocket: false
        )
        guard result.succeeded else {
            showSessionError(
                title: "Couldn’t List Sessions",
                output: result.errorOutput
            )
            return
        }
        do {
            sessions = try SessionListParser.parse(result.standardOutput)
            if remoteTarget == nil,
               let current = sessions.first(where: {
                   Self.pathsMatch($0.socketPath, activeSocketPath)
               }) {
                currentSessionName = current.name
            }
        } catch {
            sessionAlert = SessionAlert(
                kind: .error(
                    title: "Couldn’t List Sessions",
                    message: "Herdr returned an unreadable session list."
                )
            )
        }
    }

    private func startSession(
        named name: String,
        requireNew: Bool,
        attemptID: UUID
    ) async {
        await reloadSessions()
        guard attemptID == connectionAttemptID else { return }
        let existing = sessions.first(where: { $0.name == name })
        if requireNew, existing != nil {
            sessionAlert = SessionAlert(
                kind: .error(
                    title: "Session Already Exists",
                    message: "Choose a different name for the new session."
                )
            )
            return
        }
        if let existing, existing.isRunning {
            await connect(
                toSocket: existing.socketPath,
                sessionName: existing.name,
                remote: nil
            )
            return
        }

        let process = configuredHerdrProcess(
            ["--session", name, "server"],
            usesActiveSocket: false
        )
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self, weak process] _ in
            Task { @MainActor [weak self, weak process] in
                guard let self, let process,
                      self.launchedSessionServers[name] === process else {
                    return
                }
                self.launchedSessionServers.removeValue(forKey: name)
                await self.reloadSessions()
            }
        }
        do {
            try process.run()
            launchedSessionServers[name] = process
        } catch {
            sessionAlert = SessionAlert(
                kind: .error(
                    title: "Couldn’t Start Session",
                    message: error.localizedDescription
                )
            )
            return
        }

        let expectedSocket = existing?.socketPath ?? NSString(
            string: "~/.config/herdr/sessions/\(name)/herdr.sock"
        ).expandingTildeInPath
        for _ in 0..<50 {
            guard attemptID == connectionAttemptID else { return }
            if FileManager.default.fileExists(atPath: expectedSocket) {
                await reloadSessions()
                guard attemptID == connectionAttemptID else { return }
                if let session = sessions.first(where: {
                    $0.name == name && $0.isRunning
                }) {
                    await connect(
                        toSocket: session.socketPath,
                        sessionName: session.name,
                        remote: nil
                    )
                    return
                }
            }
            if !process.isRunning { break }
            try? await Task.sleep(for: .milliseconds(100))
        }

        if process.isRunning {
            process.terminate()
        }
        showSessionError(
            title: "Couldn’t Start Session",
            output: "The Herdr session server did not become ready."
        )
        await reloadSessions()
    }

    private func remoteTunnelDidExit(
        id: UUID,
        attemptID: UUID,
        message: String
    ) {
        if remoteConnection?.id == id {
            remoteConnection = nil
            let label = currentSessionDisplayName
            disconnectCurrentHerd(message: "SSH tunnel closed: \(message)")
            sessionAlert = SessionAlert(
                kind: .error(
                    title: "Remote Herd Disconnected",
                    message: "\(label): \(message)"
                )
            )
            return
        }
        guard attemptID == connectionAttemptID else { return }
        connectionAttemptID = UUID()
        sessionAlert = SessionAlert(
            kind: .error(
                title: "Remote Herd Disconnected",
                message: message
            )
        )
    }

    private func isViewing(_ session: HerdrSession) -> Bool {
        remoteTarget == nil && Self.pathsMatch(session.socketPath, activeSocketPath)
    }

    private func showSessionError(title: String, output: String) {
        sessionAlert = SessionAlert(
            kind: .error(
                title: title,
                message: output.isEmpty ? "The Herdr command failed." : output
            )
        )
    }

    private static func inferredSessionName(for socketPath: String) -> String {
        let expanded = NSString(string: socketPath).expandingTildeInPath
        if pathsMatch(expanded, defaultSocketPathWithoutEnvironment()) {
            return "default"
        }
        let url = URL(fileURLWithPath: expanded)
        if url.lastPathComponent == "herdr.sock",
           url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
               == "sessions" {
            return url.deletingLastPathComponent().lastPathComponent
        }
        return url.deletingPathExtension().lastPathComponent
    }

    private static func defaultSocketPathWithoutEnvironment() -> String {
        NSString(string: "~/.config/herdr/herdr.sock").expandingTildeInPath
    }

    private static func pathsMatch(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: NSString(string: lhs).expandingTildeInPath)
            .standardizedFileURL.path
            == URL(fileURLWithPath: NSString(string: rhs).expandingTildeInPath)
            .standardizedFileURL.path
    }

    private static func isValidSessionName(_ name: String) -> Bool {
        !name.isEmpty
            && name.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0)
                    || "._-".unicodeScalars.contains($0)
            }
    }

    func select(tab: HerdrTab) {
        guard let snapshot else { return }
        let candidates = snapshot.panes.filter { $0.tabID == tab.tabID }
        let layoutFocus = snapshot.layouts.first { $0.tabID == tab.tabID }?.focusedPaneID
        guard let pane = candidates.first(where: { $0.paneID == layoutFocus })
            ?? candidates.first(where: \.focused)
            ?? candidates.first else {
            return
        }
        select(paneID: pane.paneID, focusInHerdr: true)
    }

    func select(workspace: Workspace) {
        guard let snapshot else { return }
        let tabs = snapshot.tabs
            .filter { $0.workspaceID == workspace.workspaceID }
                    if let tab = tabs.first(where: { $0.tabID == workspace.activeTabID }) ?? tabs.first {
            select(tab: tab)
        }
    }

    /// Reveals a drag target tab locally. Herdr focus changes only if the pane is
    /// actually dropped or the user explicitly selects a pane.
    func previewTabDuringPaneDrag(_ tab: HerdrTab) {
        guard draggedPaneID != nil, let snapshot else { return }
        let candidates = snapshot.panes.filter { $0.tabID == tab.tabID }
        let layoutFocus = snapshot.layouts.first { $0.tabID == tab.tabID }?.focusedPaneID
        selectedPaneID = candidates.first(where: { $0.paneID == layoutFocus })?.paneID
            ?? candidates.first?.paneID
    }

    func select(paneID: String, focusInHerdr: Bool) {
        selectedPaneID = paneID
        guard focusInHerdr else { return }
        let client = client
        let generation = connectionGeneration
        Task {
            do {
                try await client.focusPane(paneID)
            } catch {
                if generation == connectionGeneration {
                    connectionState = .disconnected(error.localizedDescription)
                }
            }
        }
    }

    func pluginActions(for context: PluginAction.Context) -> [PluginAction] {
        pluginActions.filter { $0.contexts.isEmpty || $0.contexts.contains(context) }
    }

    func refreshPluginActions() {
        let generation = connectionGeneration
        Task {
            await refreshPluginActions(generation: generation)
        }
    }

    func invokePluginAction(_ action: PluginAction, forWorkspace workspace: Workspace) {
        guard let paneID = preferredPaneID(forWorkspaceID: workspace.workspaceID) else { return }
        invokePluginAction(action, focusedPaneID: paneID)
    }

    func invokePluginAction(_ action: PluginAction, forTab tab: HerdrTab) {
        guard let paneID = preferredPaneID(forTabID: tab.tabID) else { return }
        invokePluginAction(action, focusedPaneID: paneID)
    }

    func invokePluginAction(_ action: PluginAction, forPane paneID: String) {
        guard snapshot?.panes.contains(where: { $0.paneID == paneID }) == true else { return }
        invokePluginAction(action, focusedPaneID: paneID)
    }

    private func preferredPaneID(forWorkspaceID workspaceID: String) -> String? {
        guard let snapshot,
              let workspace = snapshot.workspaces.first(where: {
                  $0.workspaceID == workspaceID
              }) else {
            return nil
        }
        let tabs = snapshot.tabs.filter { $0.workspaceID == workspaceID }
        guard let tab = tabs.first(where: { $0.tabID == workspace.activeTabID })
            ?? tabs.first else {
            return nil
        }
        return preferredPaneID(forTabID: tab.tabID)
    }

    private func preferredPaneID(forTabID tabID: String) -> String? {
        guard let snapshot else { return nil }
        let panes = snapshot.panes.filter { $0.tabID == tabID }
        let layoutFocus = snapshot.layouts.first { $0.tabID == tabID }?.focusedPaneID
        return panes.first(where: { $0.paneID == layoutFocus })?.paneID
            ?? panes.first(where: \.focused)?.paneID
            ?? panes.first?.paneID
    }

    private func invokePluginAction(_ action: PluginAction, focusedPaneID paneID: String) {
        selectedPaneID = paneID
        let client = client
        let generation = connectionGeneration
        Task {
            do {
                try await client.focusPane(paneID)
            } catch {
                if generation == connectionGeneration {
                    connectionState = .disconnected(error.localizedDescription)
                }
                return
            }
            guard generation == connectionGeneration else { return }
            let ack = await runHerdrCapture([
                "plugin", "action", "invoke", action.id,
                "--plugin", action.pluginId,
            ])
            guard generation == connectionGeneration else { return }
            await refreshSnapshot(keepSelection: false)
            // The action runs async — its real output lands in the plugin log.
            // Poll for it and surface any text (empty output = nothing to show).
            guard let ack,
                  let data = ack.data(using: .utf8),
                  let logID = try? JSONDecoder()
                      .decode(PluginActionInvokeResponse.self, from: data)
                      .result.log?.logID
            else { return }
            let output = await pluginLogOutput(pluginID: action.pluginId, logID: logID)
            guard generation == connectionGeneration,
                  let output, !output.isEmpty else { return }
            statusExplanation = StatusExplanation(
                id: UUID(),
                title: action.title,
                text: output
            )
        }
    }

    /// Polls the plugin log for a just-invoked action until it finishes, then
    /// returns its stdout (or stderr/exit info on failure). Nil while still
    /// running past the timeout or when there's nothing to show.
    private func pluginLogOutput(pluginID: String, logID: String) async -> String? {
        for _ in 0..<24 {  // ~6s at 250ms
            guard let raw = await runHerdrCapture([
                "plugin", "log", "list", "--plugin", pluginID, "--limit", "25",
            ]),
                  let data = raw.data(using: .utf8),
                  let entry = try? JSONDecoder()
                      .decode(PluginLogListResponse.self, from: data)
                      .result.logs.first(where: { $0.logID == logID })
            else {
                try? await Task.sleep(for: .milliseconds(250))
                continue
            }
            if entry.status == "running" {
                try? await Task.sleep(for: .milliseconds(250))
                continue
            }
            let out = entry.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let err = entry.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if entry.status == "failed" || (entry.exitCode ?? 0) != 0 {
                let parts = [out, err].filter { !$0.isEmpty }
                return parts.isEmpty
                    ? "Action failed (exit \(entry.exitCode ?? -1))."
                    : parts.joined(separator: "\n\n")
            }
            // On success, only surface human-readable text (a version, a URL…).
            // Machine JSON (e.g. a pane-open confirmation) is noise — the action's
            // visible effect is the feedback.
            if out.isEmpty || out.hasPrefix("{") || out.hasPrefix("[") { return nil }
            return out
        }
        return nil
    }

    func refreshNow() {
        Task { await refreshSnapshot(keepSelection: true) }
    }

    // MARK: - Find and act

    func toggleCommandPalette() {
        isCommandPalettePresented.toggle()
        if isCommandPalettePresented {
            paletteQuery = ""
            paletteSelectedID = paletteResults.first?.id
        }
    }

    func closeCommandPalette() {
        isCommandPalettePresented = false
    }

    var paletteResults: [CommandPaletteItem] {
        FuzzyMatcher.ranked(commandPaletteItems, query: paletteQuery, text: \.label)
    }

    func paletteMove(_ delta: Int) {
        let results = paletteResults
        guard !results.isEmpty else { return }
        let current = paletteSelectedID.flatMap { id in
            results.firstIndex { $0.id == id }
        } ?? 0
        paletteSelectedID = results[min(max(current + delta, 0), results.count - 1)].id
    }

    func paletteActivate() {
        let results = paletteResults
        if let item = results.first(where: { $0.id == paletteSelectedID }) ?? results.first {
            jump(to: item)
        }
    }

    func jump(to item: CommandPaletteItem) {
        guard let snapshot else { return }
        closeCommandPalette()
        switch item.destination {
        case .tab(let tabID):
            if let tab = snapshot.tabs.first(where: { $0.tabID == tabID }) {
                select(tab: tab)
            }
        case .workspace(let workspaceID):
            if let workspace = snapshot.workspaces.first(where: {
                $0.workspaceID == workspaceID
            }) {
                select(workspace: workspace)
            }
        }
    }

    func beginRename(tab: HerdrTab) {
        guard let snapshot else { return }
        renameRequest = RenameRequest(
            target: .tab(tab.tabID),
            title: "Rename Agent",
            initialLabel: snapshot.displayLabel(for: tab)
        )
    }

    func beginRename(workspace: Workspace) {
        renameRequest = RenameRequest(
            target: .workspace(workspace.workspaceID),
            title: "Rename Space",
            initialLabel: workspace.label
        )
    }

    func commitRename(_ request: RenameRequest, label: String) {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        renameRequest = nil
        guard !label.isEmpty, label != request.initialLabel else { return }
        switch request.target {
        case .tab(let tabID):
            runAction(["tab", "rename", tabID, label], followFocus: false)
        case .workspace(let workspaceID):
            runAction(["workspace", "rename", workspaceID, label], followFocus: false)
        }
    }

    // In-place rename: begin editing a row's name inline, then commit or cancel.
    func beginInlineRename(tab: HerdrTab) { inlineRename = .tab(tab.tabID) }
    func beginInlineRename(workspace: Workspace) { inlineRename = .workspace(workspace.workspaceID) }
    func cancelInlineRename() { inlineRename = nil }

    func commitInlineRename(tab: HerdrTab, to rawLabel: String) {
        let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        inlineRename = nil
        guard !label.isEmpty, label != snapshot?.displayLabel(for: tab) else { return }
        runAction(["tab", "rename", tab.tabID, label], followFocus: false)
    }

    func commitInlineRename(workspace: Workspace, to rawLabel: String) {
        let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        inlineRename = nil
        guard !label.isEmpty, label != workspace.label else { return }
        runAction(["workspace", "rename", workspace.workspaceID, label], followFocus: false)
    }

    func close(tab: HerdrTab) {
        guard let record = closedTabRecord(for: tab) else { return }
        closedTabs.append(record)
        if closedTabs.count > 10 {
            closedTabs.removeFirst(closedTabs.count - 10)
        }
        guard let arguments = closeTabArguments(tabID: tab.tabID) else { return }
        runAction(arguments)
    }

    private func closeTabArguments(tabID: String) -> [String]? {
        guard let tab = snapshot?.tabs.first(where: { $0.tabID == tabID }),
              let workspace = snapshot?.workspaces.first(where: {
                  $0.workspaceID == tab.workspaceID
              }) else {
            return nil
        }
        if workspace.tabCount == 1 {
            return ["workspace", "close", workspace.workspaceID]
        }
        return ["tab", "close", tabID]
    }

    private func closedTabRecord(for tab: HerdrTab) -> ClosedTabRecord? {
        guard let snapshot else { return nil }
        let panes = snapshot.panes.filter { $0.tabID == tab.tabID }
        let focusedPaneID = snapshot.layouts.first {
            $0.tabID == tab.tabID
        }?.focusedPaneID
        guard let activePane = panes.first(where: { $0.paneID == focusedPaneID })
            ?? panes.first(where: \.focused)
            ?? panes.first else {
            return nil
        }
        let agentKind = panes.compactMap { pane -> AgentLaunchKind? in
            guard let agent = pane.agent?.lowercased() else { return nil }
            if agent.contains("claude") { return .claude }
            if agent.contains("codex") { return .codex }
            return nil
        }.first
        return ClosedTabRecord(
            workspaceID: tab.workspaceID,
            cwd: activePane.foregroundCWD ?? activePane.cwd,
            agentKind: agentKind,
            label: tab.label
        )
    }

    func requestClose(workspace: Workspace) {
        if workspace.tabCount > 1 {
            workspacePendingClose = workspace
        } else {
            close(workspace: workspace)
        }
    }

    func confirmCloseWorkspace() {
        guard let workspace = workspacePendingClose else { return }
        workspacePendingClose = nil
        close(workspace: workspace)
    }

    // MARK: - Worktrees

    func beginCreateWorktree(from workspace: Workspace) {
        guard let context = worktreeContext(for: workspace) else { return }
        worktreeCreateRequest = WorktreeCreateRequest(context: context)
    }

    func createWorktree(branch: String, base: String, label: String) {
        guard let request = worktreeCreateRequest else { return }
        let branch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else { return }

        worktreeCreateRequest = nil
        let existingWorkspaceIDs = Set(snapshot?.workspaces.map(\.workspaceID) ?? [])
        var arguments = [
            "worktree", "create",
            "--cwd", request.context.checkoutPath,
            "--branch", branch,
        ]
        if !base.isEmpty {
            arguments += ["--base", base]
        }
        if !label.isEmpty {
            arguments += ["--label", label]
        }
        arguments.append("--no-focus")
        let generation = connectionGeneration

        Task {
            let result = await runHerdrResult(arguments)
            guard generation == connectionGeneration else { return }
            guard result.succeeded else {
                showWorktreeError(
                    title: "Couldn’t Create Worktree",
                    output: result.errorOutput
                )
                return
            }
            await refreshSnapshot(keepSelection: true)
            selectNewWorktreeWorkspace(
                excluding: existingWorkspaceIDs,
                repoName: request.context.repoName
            )
        }
    }

    func beginOpenWorktree(from workspace: Workspace) {
        guard let context = worktreeContext(for: workspace) else { return }
        var request = WorktreeOpenRequest(context: context)
        worktreeOpenRequest = request
        let generation = connectionGeneration

        Task {
            let result = await runHerdrResult([
                "worktree", "list",
                "--cwd", context.checkoutPath,
                "--json",
            ])
            guard generation == connectionGeneration,
                  worktreeOpenRequest?.id == request.id else {
                return
            }

            request.isLoading = false
            if result.succeeded {
                do {
                    request.worktrees = try WorktreeListParser.parse(result.standardOutput)
                } catch {
                    request.error = "Herdr returned an unreadable worktree list."
                }
            } else {
                request.error = result.errorOutput.isEmpty
                    ? "Herdr couldn’t list worktrees for this repository."
                    : result.errorOutput
            }
            worktreeOpenRequest = request
        }
    }

    func openWorktree(_ worktree: HerdrWorktree) {
        guard let request = worktreeOpenRequest else { return }
        worktreeOpenRequest = nil
        let existingWorkspaceIDs = Set(snapshot?.workspaces.map(\.workspaceID) ?? [])
        let generation = connectionGeneration

        Task {
            let result = await runHerdrResult([
                "worktree", "open",
                "--cwd", request.context.checkoutPath,
                "--path", worktree.path,
                "--no-focus",
            ])
            guard generation == connectionGeneration else { return }
            guard result.succeeded else {
                showWorktreeError(
                    title: "Couldn’t Open Worktree",
                    output: result.errorOutput
                )
                return
            }
            await refreshSnapshot(keepSelection: true)
            if let workspaceID = worktree.openWorkspaceID,
               selectWorkspace(id: workspaceID) {
                return
            }
            if let workspace = snapshot?.workspaces.first(where: {
                pathsMatch($0.worktree?.checkoutPath, worktree.path)
            }) {
                select(workspace: workspace)
                return
            }
            selectNewWorktreeWorkspace(
                excluding: existingWorkspaceIDs,
                repoName: request.context.repoName
            )
        }
    }

    func requestRemoveWorktree(_ workspace: Workspace) {
        guard workspace.worktree?.isLinkedWorktree == true else { return }
        worktreeAlert = WorktreeAlert(kind: .confirmRemoval(workspace))
    }

    func confirmRemoveWorktree(_ workspace: Workspace, force: Bool) {
        worktreeAlert = nil
        let generation = connectionGeneration
        Task {
            var arguments = [
                "worktree", "remove",
                "--workspace", workspace.workspaceID,
            ]
            if force {
                arguments.append("--force")
            }
            let result = await runHerdrResult(arguments)
            guard generation == connectionGeneration else { return }
            guard result.succeeded else {
                if !force, Self.isDirtyWorktreeError(result.errorOutput) {
                    worktreeAlert = WorktreeAlert(kind: .confirmForcedRemoval(workspace))
                } else {
                    showWorktreeError(
                        title: "Couldn’t Remove Worktree",
                        output: result.errorOutput
                    )
                }
                return
            }
            await refreshSnapshot(keepSelection: false)
        }
    }

    private func worktreeContext(for workspace: Workspace) -> WorktreeRepositoryContext? {
        guard let worktree = workspace.worktree else { return nil }
        return WorktreeRepositoryContext(
            repoName: worktree.repoName,
            checkoutPath: worktree.checkoutPath
        )
    }

    private func selectNewWorktreeWorkspace(
        excluding workspaceIDs: Set<String>,
        repoName: String
    ) {
        guard let workspace = snapshot?.workspaces.first(where: {
            !workspaceIDs.contains($0.workspaceID)
                && $0.worktree?.repoName == repoName
                && $0.worktree?.isLinkedWorktree == true
        }) else {
            return
        }
        select(workspace: workspace)
    }

    @discardableResult
    private func selectWorkspace(id workspaceID: String) -> Bool {
        guard let workspace = snapshot?.workspaces.first(where: {
            $0.workspaceID == workspaceID
        }) else {
            return false
        }
        select(workspace: workspace)
        return true
    }

    private func pathsMatch(_ lhs: String?, _ rhs: String) -> Bool {
        guard let lhs else { return false }
        return URL(fileURLWithPath: lhs).standardizedFileURL.path
            == URL(fileURLWithPath: rhs).standardizedFileURL.path
    }

    private func showWorktreeError(title: String, output: String) {
        worktreeAlert = WorktreeAlert(
            kind: .error(
                title: title,
                message: output.isEmpty ? "The Herdr command failed." : output
            )
        )
    }

    private static func isDirtyWorktreeError(_ output: String) -> Bool {
        let output = output.lowercased()
        return output.contains("dirty_worktree_requires_force")
            || output.contains("modified or untracked files")
            || output.contains("worktree is dirty")
    }

    func explainStatus(tab: HerdrTab) {
        guard let snapshot,
              let pane = preferredPane(in: tab, snapshot: snapshot) else {
            showMissingExplanation(for: snapshot?.displayLabel(for: tab) ?? tab.label)
            return
        }
        beginExplanation(
            target: pane.terminalID.isEmpty ? pane.paneID : pane.terminalID,
            title: "Why \(snapshot.displayLabel(for: tab)) is \(statusLabel(tab.agentStatus))"
        )
    }

    func explainStatus(workspace: Workspace) {
        guard let snapshot else {
            showMissingExplanation(for: workspace.label)
            return
        }
        let tabs = snapshot.tabs
            .filter { $0.workspaceID == workspace.workspaceID }
                    let activeTab = tabs.first(where: { $0.tabID == workspace.activeTabID })
        let tab = activeTab?.agentStatus == workspace.agentStatus
            ? activeTab
            : tabs.first(where: { $0.agentStatus == workspace.agentStatus }) ?? activeTab
        guard let tab = tab ?? tabs.first,
              let pane = preferredPane(in: tab, snapshot: snapshot) else {
            showMissingExplanation(for: workspace.label)
            return
        }
        beginExplanation(
            target: pane.terminalID.isEmpty ? pane.paneID : pane.terminalID,
            title: "Why \(workspace.label) is \(statusLabel(workspace.agentStatus))"
        )
    }

    func moveTab(sourceTabID: String, onto targetTabID: String) {
        guard sourceTabID != targetTabID,
              let snapshot,
              let source = snapshot.tabs.first(where: { $0.tabID == sourceTabID }),
              let target = snapshot.tabs.first(where: { $0.tabID == targetTabID }),
              source.workspaceID == target.workspaceID else {
            return
        }
        let tabs = snapshot.tabs.filter { $0.workspaceID == target.workspaceID }
        guard let insertIndex = tabs.firstIndex(where: { $0.tabID == targetTabID }) else {
            return
        }
        let client = client
        let generation = connectionGeneration
        Task {
            do {
                try await client.moveTab(sourceTabID, insertIndex: insertIndex)
                guard generation == connectionGeneration else { return }
                await refreshSnapshot(keepSelection: true)
            } catch {
                if generation == connectionGeneration {
                    connectionState = .disconnected(error.localizedDescription)
                }
            }
        }
    }

    func moveWorkspace(sourceWorkspaceID: String, onto targetWorkspaceID: String) {
        guard sourceWorkspaceID != targetWorkspaceID, let snapshot else { return }
        let workspaces = snapshot.workspaces
        guard workspaces.contains(where: { $0.workspaceID == sourceWorkspaceID }),
              let insertIndex = workspaces.firstIndex(where: {
                  $0.workspaceID == targetWorkspaceID
              }) else {
            return
        }
        let client = client
        let generation = connectionGeneration
        Task {
            do {
                try await client.moveWorkspace(sourceWorkspaceID, insertIndex: insertIndex)
                guard generation == connectionGeneration else { return }
                await refreshSnapshot(keepSelection: true)
            } catch {
                if generation == connectionGeneration {
                    connectionState = .disconnected(error.localizedDescription)
                }
            }
        }
    }

    private func close(workspace: Workspace) {
        runAction(["workspace", "close", workspace.workspaceID])
    }

    private func preferredPane(in tab: HerdrTab, snapshot: SessionSnapshot) -> Pane? {
        let panes = snapshot.panes.filter { $0.tabID == tab.tabID }
        let matchingStatus = panes.filter { $0.agentStatus == tab.agentStatus }
        if let selectedPaneID,
           let selected = matchingStatus.first(where: { $0.paneID == selectedPaneID }) {
            return selected
        }
        let focusedPaneID = snapshot.layouts.first { $0.tabID == tab.tabID }?.focusedPaneID
        return matchingStatus.first(where: { $0.paneID == focusedPaneID })
            ?? matchingStatus.first
            ?? panes.first(where: { $0.paneID == selectedPaneID })
            ?? panes.first(where: { $0.paneID == focusedPaneID })
            ?? panes.first(where: \.focused)
            ?? panes.first
    }

    private func beginExplanation(target: String, title: String) {
        let id = UUID()
        statusExplanation = StatusExplanation(id: id, title: title, text: nil)
        let generation = connectionGeneration
        Task {
            let output = await runHerdrCapture(["agent", "explain", target, "--json"])
            guard generation == connectionGeneration,
                  statusExplanation?.id == id else {
                return
            }
            statusExplanation = StatusExplanation(
                id: id,
                title: title,
                text: output.map(Self.prettyPrintedJSON)
                    ?? "Herdr could not explain this status."
            )
        }
    }

    private func showMissingExplanation(for label: String) {
        statusExplanation = StatusExplanation(
            id: UUID(),
            title: "Explain \(label)",
            text: "No pane is available for this agent or space."
        )
    }

    private func statusLabel(_ status: AgentStatus) -> String {
        status == .blocked ? "blocked" : status.rawValue
    }

    private static func prettyPrintedJSON(_ output: String) -> String {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys]
              ),
              let formatted = String(data: pretty, encoding: .utf8) else {
            return output
        }
        return formatted
    }

    private func startEventLoop(client: HerdrClient, generation: UUID) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, generation == connectionGeneration {
                do {
                    let paneIDs = snapshot?.panes.map(\.paneID) ?? []
                    for try await event in client.events(paneIDs: paneIDs) {
                        guard generation == connectionGeneration else { break }
                        queue(event, generation: generation)
                    }
                } catch {
                    if !Task.isCancelled, generation == connectionGeneration {
                        connectionState = .disconnected(error.localizedDescription)
                    }
                }
                guard !Task.isCancelled, generation == connectionGeneration else { break }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func queue(_ event: HerdrEvent, generation: UUID) {
        guard generation == connectionGeneration else { return }
        pendingEvents.append(event)
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !Task.isCancelled else { return }
            await self.flushEvents(generation: generation)
        }
    }

    private func flushEvents(generation: UUID) async {
        guard generation == connectionGeneration else { return }
        let events = pendingEvents
        pendingEvents.removeAll(keepingCapacity: true)
        flushTask = nil
        guard !events.isEmpty else { return }
        bridgeServer.relay(events: events)

        // The terminal content itself is rendered by each pane's attach process,
        // so we only need to re-snapshot on structural changes (create/close/move/
        // focus/status) — never on raw output.
        let structural = events.contains { $0.name != "pane.output_changed" }
        if structural {
            await refreshSnapshot(keepSelection: true)
        }
    }

    private func refreshSnapshot(keepSelection: Bool) async {
        await refreshSnapshot(
            keepSelection: keepSelection,
            client: client,
            generation: connectionGeneration
        )
    }

    private func refreshSnapshot(
        keepSelection: Bool,
        client: HerdrClient,
        generation: UUID
    ) async {
        do {
            let newSnapshot = try await client.snapshot()
            guard generation == connectionGeneration else { return }
            let newStatuses = Dictionary(
                uniqueKeysWithValues: newSnapshot.panes.map {
                    ($0.paneID, $0.agentStatus)
                }
            )
            let transitions = lastObservedPaneStatuses.map {
                StatusTransitions.detect(from: $0, to: newStatuses)
            } ?? []
            lastObservedPaneStatuses = newStatuses

            snapshot = newSnapshot
            terminalPool.retain(
                terminalIDs: Set(newSnapshot.panes.map(\.terminalID))
            )
            connectionState = .connected(
                version: newSnapshot.version,
                protocolVersion: newSnapshot.protocol
            )
            await refreshPluginActions(generation: generation)
            guard generation == connectionGeneration else { return }

            let selectionStillValid = selectedPaneID.map { id in
                newSnapshot.panes.contains { $0.paneID == id }
            } ?? false

            if !(keepSelection && selectionStillValid) {
                selectedPaneID = newSnapshot.focusedPaneID
                    ?? newSnapshot.panes.first(where: \.focused)?.paneID
                    ?? newSnapshot.panes.first?.paneID
            }

            snapshotObserver?.raiModel(
                self,
                didRefresh: newSnapshot,
                transitions: transitions
            )
            bridgeServer.relay(snapshot: newSnapshot)
        } catch {
            if generation == connectionGeneration {
                connectionState = .disconnected(error.localizedDescription)
            }
        }
    }

    // MARK: - Keyboard actions

    // Pure navigation is resolved from the snapshot with no round-trip — instant.
    func nextTab() { cycleTab(+1) }
    func prevTab() { cycleTab(-1) }

    private func cycleTab(_ delta: Int) {
        let tabs = selectedWorkspaceTabs
        guard !tabs.isEmpty else { return }
        guard let current = selectedTabID,
              let index = tabs.firstIndex(where: { $0.tabID == current }) else {
            select(tab: tabs[0]); return
        }
        select(tab: tabs[(index + delta + tabs.count) % tabs.count])
    }

    func selectTab(index: Int) {
        let tabs = selectedWorkspaceTabs
        guard tabs.indices.contains(index) else { return }
        select(tab: tabs[index])
    }

    func nextWorkspace() { cycleWorkspace(+1) }
    func prevWorkspace() { cycleWorkspace(-1) }

    private func cycleWorkspace(_ delta: Int) {
        guard let snapshot else { return }
        let spaces = snapshot.workspaces
        guard !spaces.isEmpty else { return }
        let index = spaces.firstIndex { $0.workspaceID == selectedWorkspace?.workspaceID } ?? 0
        let target = spaces[(index + delta + spaces.count) % spaces.count]
        let tabs = snapshot.tabs
            .filter { $0.workspaceID == target.workspaceID }
                    if let tab = tabs.first(where: { $0.tabID == target.activeTabID }) ?? tabs.first {
            select(tab: tab)
        }
    }

    // Structural changes go through the herdr CLI (the binary rai already
    // spawns for attach), then we adopt herdr's resulting focus.
    func newTab() {
        guard let workspace = selectedWorkspace?.workspaceID else { return }
        runAction(["tab", "create", "--workspace", workspace, "--focus"])
    }
    func reopenClosedTab() {
        guard let record = closedTabs.popLast() else { return }
        let generation = connectionGeneration
        Task {
            await reconstructClosedTab(record, generation: generation)
        }
    }
    func closeTab() {
        guard let tab = selectedTab else { return }
        close(tab: tab)
    }
    func newWorkspace() {
        runAction(["workspace", "create", "--focus"])
    }
    func splitRight() { splitPane("right") }
    func splitDown() { splitPane("down") }
    private func splitPane(_ direction: String) {
        guard let pane = selectedPaneID else { return }
        runAction(["pane", "split", pane, "--direction", direction, "--focus"])
    }
    func closePane() {
        guard let pane = selectedPaneID else { return }
        runAction(["pane", "close", pane])
    }

    func renamePane(paneID: String, to rawLabel: String) {
        let arguments = renamePaneArguments(paneID: paneID, label: rawLabel)
        let client = client
        let generation = connectionGeneration
        Task {
            _ = await runHerdr(arguments)
            guard generation == connectionGeneration else { return }
            await refreshSnapshot(
                keepSelection: true,
                client: client,
                generation: generation
            )
        }
    }

    private func renamePaneArguments(paneID: String, label rawLabel: String) -> [String] {
        let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty
            ? ["pane", "rename", paneID, "--clear"]
            : ["pane", "rename", paneID, label]
    }

    func processInfo(for paneID: String) async -> PaneProcessInfo? {
        let generation = connectionGeneration
        guard let output = await runHerdrCapture([
            "pane", "process-info", "--pane", paneID,
        ]),
        generation == connectionGeneration,
        let data = output.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(PaneProcessInfoResponse.self, from: data)
            .result.processInfo
    }

    // Codex Micro: send Return to the currently focused pane (the mic-adjacent key).
    func microSendReturnToSelectedPane() {
        guard let paneID = selectedPaneID else { return }
        Task { _ = await runHerdr(["pane", "send-keys", paneID, "Enter"]) }
    }

    func microSendKeysToSelectedPane(_ keys: String) {
        guard let paneID = selectedPaneID, !keys.isEmpty else { return }
        Task { _ = await runHerdr(["pane", "send-keys", paneID, keys]) }
    }

    func microSendTextToSelectedPane(_ text: String, submit: Bool) {
        guard let paneID = selectedPaneID, !text.isEmpty else { return }
        Task {
            guard await runHerdr(["pane", "send-text", paneID, text]),
                  submit else {
                return
            }
            _ = await runHerdr(["pane", "send-keys", paneID, "Enter"])
        }
    }

    func broadcast(text: String) {
        guard !text.isEmpty else { return }
        let paneIDs = visiblePanes.map(\.paneID)
        guard !paneIDs.isEmpty else { return }
        let client = client
        let generation = connectionGeneration
        Task {
            for paneID in paneIDs {
                guard await runHerdr(["pane", "send-text", paneID, text]) else {
                    continue
                }
                _ = await runHerdr(["pane", "send-keys", paneID, "Enter"])
            }
            guard generation == connectionGeneration else { return }
            await refreshSnapshot(
                keepSelection: true,
                client: client,
                generation: generation
            )
        }
    }

    func focusPane(_ direction: String) {
        guard let pane = selectedPaneID else { return }
        runAction(["pane", "focus", "--direction", direction, "--pane", pane])
    }
    func zoomPane(_ paneID: String? = nil) {
        guard let pane = paneID ?? selectedPaneID else { return }
        selectedPaneID = pane
        runAction(["pane", "zoom", pane, "--toggle"], followFocus: false)
    }

    func dropPane(
        sourcePaneID: String,
        onto targetPaneID: String,
        moveDirection: SplitDirection
    ) {
        guard let source = snapshot?.panes.first(where: { $0.paneID == sourcePaneID }),
              let target = snapshot?.panes.first(where: { $0.paneID == targetPaneID }),
              let arguments = PaneActionPlanner.dropArguments(
                  sourcePaneID: source.paneID,
                  sourceTabID: source.tabID,
                  targetPaneID: target.paneID,
                  targetTabID: target.tabID,
                  moveDirection: moveDirection
              ) else {
            return
        }
        runAction(arguments, followFocus: false)
    }

    func launchAgent(
        _ kind: AgentLaunchKind,
        direction: SplitDirection,
        from paneID: String? = nil
    ) {
        guard let paneID = paneID ?? selectedPaneID,
              let pane = snapshot?.panes.first(where: { $0.paneID == paneID }) else {
            return
        }
        selectedPaneID = paneID
        let name = Self.defaultAgentName(kind)
        let client = client
        let generation = connectionGeneration

        Task {
            // agent start --split uses herdr's focused pane as the split source.
            // Await focus so a pane-bar action cannot race and split the wrong pane.
            do {
                try await client.focusPane(paneID)
            } catch {
                if generation == connectionGeneration {
                    connectionState = .disconnected(error.localizedDescription)
                }
                return
            }
            guard generation == connectionGeneration else { return }
            _ = await runHerdr(
                PaneActionPlanner.agentStartArguments(
                    name: name,
                    executable: kind.rawValue,
                    direction: direction,
                    cwd: pane.cwd
                )
            )
            guard generation == connectionGeneration else { return }
            await refreshSnapshot(keepSelection: true)
        }
    }

    private static func defaultAgentName(_ kind: AgentLaunchKind) -> String {
        let suffix = UUID().uuidString.prefix(6).lowercased()
        return "\(kind.rawValue)-\(suffix)"
    }

    func launchAgentFromBridge(
        _ kind: AgentLaunchKind,
        workspaceID: String?,
        cwd: String?
    ) async -> Bool {
        await runHerdr(
            PaneActionPlanner.agentStartArguments(
                name: Self.defaultAgentName(kind),
                executable: kind.rawValue,
                workspaceID: workspaceID,
                cwd: cwd
            )
        )
    }

    func renamePaneFromBridge(paneID: String, label rawLabel: String) async -> Bool {
        guard snapshot?.panes.contains(where: { $0.paneID == paneID }) == true else {
            return false
        }
        return await runHerdr(renamePaneArguments(paneID: paneID, label: rawLabel))
    }

    func renameTabFromBridge(tabID: String, label rawLabel: String) async -> Bool {
        guard snapshot?.tabs.contains(where: { $0.tabID == tabID }) == true else {
            return false
        }
        let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return false }
        return await runHerdr(["tab", "rename", tabID, label])
    }

    func closePaneFromBridge(paneID: String) async -> Bool {
        guard snapshot?.panes.contains(where: { $0.paneID == paneID }) == true else {
            return false
        }
        return await runHerdr(["pane", "close", paneID])
    }

    func closeTabFromBridge(tabID: String) async -> Bool {
        guard let arguments = closeTabArguments(tabID: tabID) else { return false }
        return await runHerdr(arguments)
    }

    private func reconstructClosedTab(
        _ record: ClosedTabRecord,
        generation: UUID
    ) async {
        guard generation == connectionGeneration else { return }
        let oldTabIDs = Set(snapshot?.tabs.map(\.tabID) ?? [])
        var workspaceID = snapshot?.workspaces.contains {
            $0.workspaceID == record.workspaceID
        } == true
            ? record.workspaceID
            : selectedWorkspace?.workspaceID
                ?? snapshot?.focusedWorkspaceID
                ?? snapshot?.workspaces.first?.workspaceID

        if workspaceID == nil {
            guard await runHerdr([
                "workspace", "create",
                "--cwd", record.cwd,
                "--focus",
            ]) else {
                return
            }
            await refreshSnapshot(keepSelection: false)
            workspaceID = snapshot?.focusedWorkspaceID
        } else if let targetWorkspaceID = workspaceID {
            var created = await runHerdr([
                "tab", "create",
                "--workspace", targetWorkspaceID,
                "--cwd", record.cwd,
                "--label", record.label,
                "--focus",
            ])
            if !created {
                // The recorded workspace may have disappeared after the close
                // but before its structural event reached Rai.
                await refreshSnapshot(keepSelection: false)
                guard let fallbackWorkspaceID = selectedWorkspace?.workspaceID
                    ?? snapshot?.focusedWorkspaceID
                    ?? snapshot?.workspaces.first?.workspaceID else {
                    return
                }
                workspaceID = fallbackWorkspaceID
                created = await runHerdr([
                    "tab", "create",
                    "--workspace", fallbackWorkspaceID,
                    "--cwd", record.cwd,
                    "--label", record.label,
                    "--focus",
                ])
            }
            guard created else { return }
            await refreshSnapshot(keepSelection: false)
        }

        guard generation == connectionGeneration,
              let workspaceID,
              let reopenedTab = snapshot?.tabs.first(where: {
                  $0.workspaceID == workspaceID && !oldTabIDs.contains($0.tabID)
              }) ?? snapshot?.tabs.first(where: {
                  $0.workspaceID == workspaceID && $0.focused
              }) else {
            return
        }

        if snapshot?.displayLabel(for: reopenedTab) != record.label {
            _ = await runHerdr(["tab", "rename", reopenedTab.tabID, record.label])
        }
        if let agentKind = record.agentKind {
            // Best effort: both clients scope their "most recent" lookup by cwd.
            // Their current CLIs support these flags, but Rai cannot verify that
            // a resumable session still exists after herdr killed it. Fall back
            // to a fresh client only when the resume command exits unsuccessfully.
            let resumeCommand: String = switch agentKind {
            case .claude: "claude --continue || exec claude"
            case .codex: "codex resume --last || exec codex"
            }
            // `tab create` already gave the tab a default shell pane, and
            // `agent start` puts the agent in a SECOND pane beside it. Capture
            // that default pane up front and close it once the agent is running,
            // so the reopened tab holds just the resumed agent — not a stray
            // extra terminal.
            let defaultPaneID = snapshot?.panes.first {
                $0.tabID == reopenedTab.tabID
            }?.paneID
            _ = await runHerdr([
                "agent", "start", Self.defaultAgentName(agentKind),
                "--tab", reopenedTab.tabID,
                "--cwd", record.cwd,
                "--focus",
                "--",
                "/bin/sh", "-lc", resumeCommand,
            ])
            if let defaultPaneID {
                _ = await runHerdr(["pane", "close", defaultPaneID])
            }
        } else {
            _ = await runHerdr(["tab", "focus", reopenedTab.tabID])
        }
        await refreshSnapshot(keepSelection: false)
    }

    // Commit a divider drag. herdr's `pane resize --amount` is a positive delta on
    // the split ratio (negative amounts don't shrink), so grow-first resizes the
    // first pane toward right/down; grow-second resizes the second pane toward
    // left/up by the absolute delta.
    func commitSplitRatio(
        splitID: String,
        direction: SplitDirection,
        firstPaneID: String,
        secondPaneID: String,
        delta: Double
    ) {
        guard abs(delta) > 0.004 else {
            dragRatios.removeValue(forKey: splitID)
            return
        }
        let horizontal = direction == .right
        let pane = delta >= 0 ? firstPaneID : secondPaneID
        let dir = delta >= 0 ? (horizontal ? "right" : "down") : (horizontal ? "left" : "up")
        let amount = String(format: "%.4f", abs(delta))
        let generation = connectionGeneration
        Task {
            _ = await runHerdr(["pane", "resize", "--pane", pane, "--direction", dir, "--amount", amount])
            guard generation == connectionGeneration else { return }
            await refreshSnapshot(keepSelection: true)
            dragRatios.removeValue(forKey: splitID)
        }
    }

    private func runAction(_ args: [String], followFocus: Bool = true) {
        let generation = connectionGeneration
        Task {
            _ = await runHerdr(args)
            guard generation == connectionGeneration else { return }
            await refreshSnapshot(keepSelection: !followFocus)
        }
    }

    private func refreshPluginActions(generation: UUID) async {
        guard let output = await runHerdrCapture(["plugin", "action", "list"]),
              generation == connectionGeneration,
              let data = output.data(using: .utf8),
              let response = try? JSONDecoder().decode(
                  PluginActionListResponse.self,
                  from: data
              ) else {
            return
        }
        pluginActions = response.result.actions
            .filter { $0.platforms.contains("macos") }
            .map(\.pluginAction)
    }

    func serverStatus() async -> String {
        await runHerdrCapture(["status", "server"])
            ?? "Unable to read the Herdr server status."
    }

    func reloadConfig() async -> Bool {
        await runHerdr(["server", "reload-config"])
    }

    func pluginList() async -> String? {
        await runHerdrCapture(["plugin", "list", "--json"])
    }

    func pluginEnable(_ pluginID: String) async -> Bool {
        await runHerdr(["plugin", "enable", pluginID])
    }

    func pluginDisable(_ pluginID: String) async -> Bool {
        await runHerdr(["plugin", "disable", pluginID])
    }

    func pluginUnlink(_ pluginID: String) async -> Bool {
        await runHerdr(["plugin", "unlink", pluginID])
    }

    func pluginLogs(_ pluginID: String) async -> String? {
        await runHerdrCapture([
            "plugin", "log", "list",
            "--plugin", pluginID,
            "--limit", "200",
        ])
    }

    func integrationInstall(_ name: String) async -> String? {
        await runHerdrCapture(["integration", "install", name])
    }

    func integrationUninstall(_ name: String) async -> String? {
        await runHerdrCapture(["integration", "uninstall", name])
    }

    func configCheck() async -> String? {
        await runHerdrCapture(["config", "check"])
    }

    func updateHerdr() async -> String {
        await runHerdrCapture(["update"])
            ?? "Herdr update failed or returned no output."
    }

    func stopServer() async -> Bool {
        await runHerdr(["server", "stop"])
    }

    private func runHerdr(_ args: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = configuredHerdrProcess(args)
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus == 0)
            }
            do { try process.run() } catch { continuation.resume(returning: false) }
        }
    }

    private func runHerdrCapture(_ args: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            let process = configuredHerdrProcess(args)
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let string = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: string?.isEmpty == false ? string : nil)
            }
        }
    }

    private struct HerdrCommandResult {
        let succeeded: Bool
        let standardOutput: String
        let standardError: String

        var errorOutput: String {
            let error = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            if !error.isEmpty {
                return error
            }
            return standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func runHerdrResult(
        _ args: [String],
        usesActiveSocket: Bool = true
    ) async -> HerdrCommandResult {
        await withCheckedContinuation { continuation in
            let process = configuredHerdrProcess(
                args,
                usesActiveSocket: usesActiveSocket
            )
            let standardOutput = Pipe()
            let standardError = Pipe()
            process.standardOutput = standardOutput
            process.standardError = standardError
            do {
                try process.run()
            } catch {
                continuation.resume(
                    returning: HerdrCommandResult(
                        succeeded: false,
                        standardOutput: "",
                        standardError: error.localizedDescription
                    )
                )
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
                let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(
                    returning: HerdrCommandResult(
                        succeeded: process.terminationStatus == 0,
                        standardOutput: String(data: outputData, encoding: .utf8) ?? "",
                        standardError: String(data: errorData, encoding: .utf8) ?? ""
                    )
                )
            }
        }
    }

    private func configuredHerdrProcess(
        _ args: [String],
        usesActiveSocket: Bool = true
    ) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: HerdrCLI.binaryPath)
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        let path = environment["PATH"] ?? ""
        if !path.contains("/opt/homebrew/bin") {
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:"
                + (path.isEmpty ? "/usr/bin:/bin" : path)
        }
        if usesActiveSocket {
            environment["HERDR_SOCKET_PATH"] = activeSocketPath
        } else {
            environment.removeValue(forKey: "HERDR_SOCKET_PATH")
        }
        process.environment = environment
        return process
    }
}
