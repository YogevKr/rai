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

enum AgentLaunchKind: String, Codable {
    case claude
    case codex
}

/// One pane of a closed tab, in tree leaf order: what reopen needs to put a
/// terminal back where it was and resume whatever ran inside it.
struct ClosedPaneSeed: Equatable, Codable {
    let cwd: String
    let agentKind: AgentLaunchKind?
    let agentSession: AgentSession?
    /// Filled asynchronously at close time, best effort — see close(tab:).
    var agentArgv: [String]? = nil

    /// Whether reopen may resume this pane's agent. The snapshot's `agent`
    /// field alone is not enough: it names the last agent SEEN in the pane,
    /// which lingers after the agent exits. Resuming on that evidence runs
    /// `--last`-style fallbacks that attach whatever session in that cwd is
    /// newest — someone else's conversation. An exact session id or argv
    /// captured from the live process is proof; anything less reopens as a
    /// plain shell.
    var canResumeAgent: Bool {
        agentKind != nil && (agentSession != nil || agentArgv != nil)
    }
}

/// The full shape of a closed tab: every pane, the split tree that arranged
/// them, and which one the user was looking at.
struct ClosedTabShape: Equatable, Codable {
    var seeds: [ClosedPaneSeed]
    let steps: [TabRebuildStep]
    let focusedLeaf: Int?
    let zoomed: Bool
}

struct ClosedTabRecord: Equatable, Codable {
    /// Identity for async enrichment: argv capture mutates the record after it
    /// is already in `closedTabs`, so equality lookups would miss. Runtime
    /// only — a decoded record gets a fresh identity, which is fine because
    /// enrichment never outlives the app run that captured it.
    let id = UUID()
    let workspaceID: String
    let cwd: String
    let agentKind: AgentLaunchKind?
    let agentSession: AgentSession?
    let label: String
    /// The agent's full command line at close time (from pane process-info):
    /// reopen relaunches with the SAME flags — bypass permissions, model
    /// picks — not a bare default invocation.
    var agentArgv: [String]?
    /// Present when the tab had more than one pane. Reopen then rebuilds the
    /// splits, per-pane cwds, and per-pane agents instead of a single pane.
    var shape: ClosedTabShape?

    /// Same evidence rule as ClosedPaneSeed.canResumeAgent, for the
    /// single-pane path.
    var canResumeAgent: Bool {
        agentKind != nil && (agentSession != nil || agentArgv != nil)
    }

    enum CodingKeys: String, CodingKey {
        case workspaceID, cwd, agentKind, agentSession, label, agentArgv, shape
    }
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

struct HerdrNewsItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let body: String
}

struct HerdrPluginInstallPreview: Identifiable {
    let id = UUID()
    let canConfirm: Bool
    let output: String
}

private final class HerdrPipeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func read(from handle: FileHandle) {
        let captured = handle.readDataToEndOfFile()
        lock.lock()
        data = captured
        lock.unlock()
    }

    func string() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private final class PendingHerdrPluginInstall: @unchecked Sendable {
    let source: String
    let resolvedCommit: String
    let socketPath: String
    let temporaryDirectory: URL

    init(
        source: String,
        resolvedCommit: String,
        socketPath: String,
        temporaryDirectory: URL
    ) {
        self.source = source
        self.resolvedCommit = resolvedCommit
        self.socketPath = socketPath
        self.temporaryDirectory = temporaryDirectory
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

private struct TabCreateResponse: Decodable {
    struct Result: Decodable {
        struct Tab: Decodable {
            let tabID: String

            enum CodingKeys: String, CodingKey {
                case tabID = "tab_id"
            }
        }

        let tab: Tab
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
    @Published var collapsedSpaceKeys: Set<String> {
        didSet {
            userDefaults.set(
                collapsedSpaceKeys.sorted(),
                forKey: Self.collapsedSpaceKeysDefaultsKey
            )
        }
    }
    @Published private(set) var workspaceGitStatuses: [String: WorkspaceGitStatus] = [:]
    @Published var notificationsMuted: Bool {
        didSet {
            userDefaults.set(
                notificationsMuted,
                forKey: Self.notificationsMutedDefaultsKey
            )
        }
    }
    // Sidebar agents panel: how it sorts, whether it is collapsed, and how much
    // of the sidebar it takes. All three outlive the launch.
    @Published var agentPanelSort: AgentPanelSort {
        didSet {
            userDefaults.set(agentPanelSort.rawValue, forKey: Self.agentPanelSortKey)
        }
    }
    @Published var agentPanelCollapsed: Bool {
        didSet {
            userDefaults.set(agentPanelCollapsed, forKey: Self.agentPanelCollapsedKey)
        }
    }
    /// Share of the sidebar body given to the spaces list, 0…1.
    @Published var sidebarSplit: Double {
        didSet {
            userDefaults.set(sidebarSplit, forKey: Self.sidebarSplitKey)
        }
    }
    @Published var isCommandPalettePresented = false
    @Published var isBroadcastPresented = false
    @Published var paletteQuery = "" {
        // Every keystroke re-ranks the list, so the old selection now points
        // at an arbitrary row. Return must mean "the top match for what I
        // typed" until the user explicitly arrows away from it.
        didSet { paletteSelectedID = paletteResults.first?.id }
    }
    @Published var paletteSelectedID: String?
    /// Row the palette list should scroll to. Only keyboard navigation sets
    /// it: hover also moves the selection, and scrolling to a hover target
    /// moves the list under a resting cursor, which hovers a new row and
    /// scrolls again — a loop that crawls the list by itself.
    @Published var paletteScrollTarget: String?
    @Published var renameRequest: RenameRequest?
    // In-place sidebar rename: which tab/space is currently editing its name.
    @Published var inlineRename: InlineRenameTarget?
    @Published var workspacePendingClose: Workspace?
    @Published var statusExplanation: StatusExplanation?
    @Published var pluginActions: [PluginAction] = []
    /// Git checkouts under `repoRoots` that no space has opened yet. Scanned on
    /// the herd's host, so they stay correct when attached to a remote herd.
    @Published private(set) var discoveredRepos: [DiscoveredRepo] = []
    @Published var worktreeCreateRequest: WorktreeCreateRequest?
    @Published var worktreeOpenRequest: WorktreeOpenRequest?
    @Published var worktreeAlert: WorktreeAlert?
    @Published private(set) var sessions: [HerdrSession] = []
    @Published private(set) var activeSocketPath: String
    @Published private(set) var currentSessionName: String
    @Published private(set) var remoteTarget: String?
    @Published private(set) var closedTabs: [ClosedTabRecord] = [] {
        // Every mutation persists — append, pop, and async argv enrichment —
        // so a relaunch keeps whatever ⌘⇧T could reach when the app quit.
        didSet { closedTabStore.save(closedTabs, herdKey: currentHerdKey) }
    }
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
    private static let agentPanelSortKey = "agentPanelSort"
    private static let agentPanelCollapsedKey = "agentPanelCollapsed"
    private static let sidebarSplitKey = "sidebarSplit"
    private static let collapsedSpaceKeysDefaultsKey = "collapsedSpaceKeys"
    private static let repoRootsKey = "repoRoots"
    private static let repoDepthKey = "repoDepth"
    static let sidebarSplitRange: ClosedRange<Double> = 0.2...0.85
    private let userDefaults: UserDefaults
    private let workspaceGitStatusCache = WorkspaceGitStatusCache()
    private lazy var closedTabStore = ClosedTabStore(userDefaults: userDefaults)

    private var currentHerdKey: String {
        ClosedTabStore.herdKey(
            sessionName: currentSessionName,
            remoteTarget: remoteTarget
        )
    }
    private var started = false
    private var eventTask: Task<Void, Never>?
    /// Where the user has been, for palette ordering. Deep enough to cover a
    /// long session, small enough that stale rows fall off on their own.
    private var navigationRecency = LRUTracker<String>(capacity: 60)
    private var repoScanTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var gitStatusTask: Task<Void, Never>?
    private var pendingEvents: [HerdrEvent] = []
    private var trailingRefreshTask: Task<Void, Never>?
    /// Connection generation whose plugin actions were already fetched, so the
    /// herdr CLI spawn happens once per connection, not once per snapshot.
    private var pluginActionsGeneration: UUID?
    private var lastObservedPaneStatuses: [String: AgentStatus]?
    private var connectionGeneration = UUID()
    private var connectionAttemptID = UUID()
    private var remoteConnection: RemoteConnection?
    private var launchedSessionServers: [String: Process] = [:]
    private var pendingPluginInstall: PendingHerdrPluginInstall?

    init(
        client: HerdrClient = HerdrClient(),
        userDefaults: UserDefaults = .standard
    ) {
        self.client = client
        activeSocketPath = client.socketPath
        currentSessionName = Self.inferredSessionName(for: client.socketPath)
        terminalPool = TerminalPool(socketPath: client.socketPath)
        self.userDefaults = userDefaults
        collapsedSpaceKeys = Set(
            userDefaults.stringArray(forKey: Self.collapsedSpaceKeysDefaultsKey) ?? []
        )
        notificationsMuted = userDefaults.bool(
            forKey: Self.notificationsMutedDefaultsKey
        )
        agentPanelSort = userDefaults.string(forKey: Self.agentPanelSortKey)
            .flatMap(AgentPanelSort.init(rawValue:)) ?? .priority
        agentPanelCollapsed = userDefaults.bool(forKey: Self.agentPanelCollapsedKey)
        // A missing default reads as 0.0 — treat that as "never set" rather than
        // opening with the spaces list squeezed to nothing.
        let storedSplit = userDefaults.double(forKey: Self.sidebarSplitKey)
        sidebarSplit = storedSplit > 0 ? Self.clampSplit(storedSplit) : 0.62
    }

    static func clampSplit(_ value: Double) -> Double {
        min(max(value, sidebarSplitRange.lowerBound), sidebarSplitRange.upperBound)
    }

    func setSidebarSplit(_ value: Double) {
        sidebarSplit = Self.clampSplit(value)
    }

    func toggleAgentPanelSort() {
        agentPanelSort = agentPanelSort.toggled
    }

    func toggleAgentPanelCollapsed() {
        agentPanelCollapsed.toggle()
    }

    /// The agents panel's rows: every agent pane in the herd, in the panel's sort.
    var agentPanelEntries: [AgentPanelEntry] {
        guard let snapshot else { return [] }
        return AgentPanel.entries(in: snapshot, sort: agentPanelSort)
    }

    deinit {
        eventTask?.cancel()
        flushTask?.cancel()
        gitStatusTask?.cancel()
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

    var workspaceListEntries: [WorkspaceListEntry] {
        guard let snapshot else { return [] }
        return WorkspaceSidebar.entries(
            in: snapshot,
            gitStatuses: workspaceGitStatuses,
            collapsedSpaceKeys: collapsedSpaceKeys,
            visibleWorkspaceID: selectedWorkspace?.workspaceID
        )
    }

    func gitStatus(for workspace: Workspace) -> WorkspaceGitStatus? {
        guard let snapshot else { return nil }
        return WorkspaceSidebar.gitStatus(
            for: workspace,
            in: snapshot,
            gitStatuses: workspaceGitStatuses
        )
    }

    func toggleSpaceGroupCollapsed(_ key: String) {
        if collapsedSpaceKeys.contains(key) {
            collapsedSpaceKeys.remove(key)
        } else {
            collapsedSpaceKeys.insert(key)
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
            // The space's checkout, so a query can name the directory the work
            // lives in rather than whatever the space was labelled.
            let checkout = WorkspaceSidebar.checkoutPath(for: workspace, in: snapshot)
            items.append(
                CommandPaletteItem(
                    id: "workspace:\(workspace.workspaceID)",
                    label: displayWorkspaceLabel,
                    workspaceLabel: displayWorkspaceLabel,
                    status: workspace.agentStatus,
                    destination: .workspace(workspace.workspaceID),
                    kind: .workspace,
                    matchPath: checkout
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
                        kind: .agent,
                        matchPath: checkout
                    )
                }
            )
        }

        // Repos with no space yet come last, so typing a name always surfaces
        // the running space before the offer to open a second one.
        let unopened = RepoDiscoveryPlanner.candidates(
            repos: discoveredRepos,
            openPaths: openWorkspacePaths
        )
        // Commands stay out of the empty-query list. With no query the palette
        // is a navigator, and a wall of verbs would bury the spaces the user
        // came for. Typing anything brings them back in, ranked by score.
        if !paletteQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let commands = PaletteCommand.builtIns() + pluginActions.map(PaletteCommand.from)
            items += commands.map { command in
                CommandPaletteItem(
                    id: command.id,
                    label: command.title,
                    workspaceLabel: command.subtitle,
                    status: .unknown,
                    destination: .command(command.effect),
                    kind: .command
                )
            }
        }

        items += unopened.map { repo in
            CommandPaletteItem(
                id: "repo:\(repo.path)",
                label: repo.name,
                workspaceLabel: RepoDiscoveryPlanner.displayPath(repo.path),
                status: .unknown,
                destination: .newSpace(path: repo.path, label: repo.name),
                kind: .repo,
                matchPath: repo.path
            )
        }

        // A typed path opens as a space even outside the project roots. Local
        // herds only: rai cannot stat a path on the remote host, and offering
        // an unverifiable row invites a create that lands in the wrong place.
        if remoteTarget == nil,
           let path = RepoDiscoveryPlanner.explicitPathQuery(paletteQuery) {
            let offered = (openWorkspacePaths + unopened.map(\.path))
                .map(RepoDiscoveryPlanner.normalized)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
               isDirectory.boolValue,
               !offered.contains(RepoDiscoveryPlanner.normalized(path)) {
                let name = RepoDiscoveryPlanner.name(for: path)
                items.append(
                    CommandPaletteItem(
                        id: "path:\(path)",
                        label: name,
                        workspaceLabel: RepoDiscoveryPlanner.displayPath(path),
                        status: .unknown,
                        destination: .newSpace(path: path, label: name),
                        kind: .repo,
                        matchPath: path
                    )
                )
            }
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
            guard attemptID == connectionAttemptID else { return }
            // Opening rai with a dead herd used to show an empty window. Start
            // the server rai points at, then connect to it.
            if snapshot == nil, let target = HerdrServerLaunch.autostartTarget(
                socketPath: activeSocketPath,
                sessions: sessions
            ) {
                connectionState = .connecting
                await startSession(
                    named: target.name,
                    requireNew: false,
                    attemptID: attemptID
                )
                guard attemptID == connectionAttemptID else { return }
                // A server that never becomes ready leaves the connection pill
                // spinning; say it is offline instead.
                if case .connecting = connectionState, snapshot == nil {
                    connectionState = .disconnected(
                        "\(target.name) is not running."
                    )
                }
            }
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
        // Swap in this herd's own reopen stack. Records name workspaces and
        // cwds on one herd's host, so the previous herd's records must not
        // stay reachable here — and this is also what restores them across
        // app launches.
        closedTabs = closedTabStore.load(herdKey: currentHerdKey)
        client = HerdrClient(socketPath: socketPath)
        terminalPool.switchSocket(to: socketPath)
        terminalPool.predictiveEchoEnabled = remote != nil
        connectionState = .connecting

        await refreshSnapshot(
            keepSelection: false,
            client: client,
            generation: generation
        )
        guard generation == connectionGeneration else { return }
        startEventLoop(client: client, generation: generation)
        refreshRepoIndex()
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
        trailingRefreshTask?.cancel()
        trailingRefreshTask = nil
        gitStatusTask?.cancel()
        gitStatusTask = nil
        // Repos belong to the herd's host, so they do not survive a switch to
        // another herd — a remote's paths mean nothing on the local one.
        repoScanTask?.cancel()
        repoScanTask = nil
        discoveredRepos = []
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
        workspaceGitStatuses = [:]
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

        let arguments = existing.map(HerdrServerLaunch.serverArguments(for:))
            ?? ["--session", name, "server"]
        let process = configuredHerdrProcess(
            arguments,
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
        // Every selection funnels through here — palette, sidebar, keyboard —
        // so this is the one place recency has to be recorded.
        if let pane = snapshot?.panes.first(where: { $0.paneID == paneID }) {
            recordVisit(tabID: pane.tabID, workspaceID: pane.workspaceID)
        }
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
            paletteScrollTarget = nil
            // Repos land as soon as the scan returns; the palette is usable
            // against open spaces in the meantime.
            refreshRepoIndex()
        }
    }

    func closeCommandPalette() {
        isCommandPalettePresented = false
    }

    var paletteResults: [CommandPaletteItem] {
        PaletteRanking.ranked(
            commandPaletteItems,
            query: paletteQuery,
            recentIDs: paletteRecentIDs
        )
    }

    /// Visited rows, most recent first, minus the row the palette would land
    /// on anyway. Dropping the current selection is what makes ⌘K then Return
    /// behave like alt-tab instead of a no-op.
    private var paletteRecentIDs: [String] {
        var current = Set<String>()
        if let tabID = selectedTabID { current.insert("tab:\(tabID)") }
        if let workspaceID = selectedWorkspace?.workspaceID {
            current.insert("workspace:\(workspaceID)")
        }
        return navigationRecency.mostToLeastRecent.filter { !current.contains($0) }
    }

    /// Records a visit so the palette can offer it back. Called on every
    /// selection, whatever made it — palette, sidebar, or keyboard.
    private func recordVisit(tabID: String?, workspaceID: String?) {
        if let workspaceID { navigationRecency.touch("workspace:\(workspaceID)") }
        if let tabID { navigationRecency.touch("tab:\(tabID)") }
    }

    func paletteMove(_ delta: Int) {
        let results = paletteResults
        guard !results.isEmpty else { return }
        let current = paletteSelectedID.flatMap { id in
            results.firstIndex { $0.id == id }
        } ?? 0
        paletteSelectedID = results[min(max(current + delta, 0), results.count - 1)].id
        paletteScrollTarget = paletteSelectedID
    }

    func paletteActivate(modifiers: PaletteModifiers = .none) {
        let results = paletteResults
        guard let item = results.first(where: { $0.id == paletteSelectedID })
            ?? results.first else { return }
        perform(
            PaletteActionDecision.resolved(
                modifiers: modifiers,
                item: item,
                isRemote: remoteTarget != nil
            ),
            on: item
        )
    }

    func perform(_ action: CommandPaletteItem.Action, on item: CommandPaletteItem) {
        switch action {
        case .open:
            jump(to: item)
        case .newTab:
            closeCommandPalette()
            jumpWithoutClosing(to: item)
            newTab()
        case .newWorktree:
            closeCommandPalette()
            beginCreateWorktree(from: item)
        case .revealInFinder:
            closeCommandPalette()
            guard let path = item.matchPath, !path.isEmpty else { return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }

    /// Starts the worktree sheet straight from a palette row. A repo row has no
    /// space yet, but `worktree create` works from a checkout path alone, so no
    /// workspace has to exist first.
    private func beginCreateWorktree(from item: CommandPaletteItem) {
        guard let path = item.matchPath, !path.isEmpty else { return }
        worktreeCreateRequest = WorktreeCreateRequest(
            context: WorktreeRepositoryContext(
                repoName: RepoDiscoveryPlanner.name(for: path),
                checkoutPath: path
            )
        )
    }

    func jump(to item: CommandPaletteItem) {
        closeCommandPalette()
        jumpWithoutClosing(to: item)
    }

    private func jumpWithoutClosing(to item: CommandPaletteItem) {
        if case .newSpace(let path, let label) = item.destination {
            openSpace(atPath: path, label: label)
            return
        }
        if case .command(let effect) = item.destination {
            run(effect)
            return
        }
        guard let snapshot else { return }
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
        case .newSpace, .command:
            break
        }
    }

    private func run(_ effect: PaletteCommand.Effect) {
        switch effect {
        case .newTab: newTab()
        case .newSpace: newWorkspace()
        case .splitRight: splitRight()
        case .splitDown: splitDown()
        case .zoomPane: zoomPane()
        case .closePane: closePane()
        case .closeTab: closeTab()
        case .broadcast: isBroadcastPresented = true
        case .reopenClosedTab: reopenClosedTab()
        case .rescanRepos: refreshRepoIndex()
        case .refresh: refreshNow()
        case .plugin(let actionID, let pluginID):
            // The focused pane is the context a plugin action gets from the
            // palette: it satisfies pane, tab, and workspace scopes at once.
            guard let paneID = selectedPaneID,
                  let action = pluginActions.first(where: {
                      $0.id == actionID && $0.pluginId == pluginID
                  }) else { return }
            invokePluginAction(action, forPane: paneID)
        }
    }

    // MARK: - Repos

    /// Project roots scanned for checkouts, newest edit wins over the default.
    var repoRoots: [String] {
        get {
            let stored = userDefaults.stringArray(forKey: Self.repoRootsKey)
            guard let stored else { return RepoDiscoveryPlanner.defaultRoots }
            return stored
        }
        set {
            let cleaned = newValue
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            objectWillChange.send()
            userDefaults.set(cleaned, forKey: Self.repoRootsKey)
            refreshRepoIndex()
        }
    }

    /// How many levels below each root a checkout may sit.
    var repoDepth: Int {
        get {
            let stored = userDefaults.integer(forKey: Self.repoDepthKey)
            guard stored > 0 else { return RepoDiscoveryPlanner.defaultDepth }
            return min(stored, RepoDiscoveryPlanner.maxDepth)
        }
        set {
            objectWillChange.send()
            userDefaults.set(
                min(max(newValue, 1), RepoDiscoveryPlanner.maxDepth),
                forKey: Self.repoDepthKey
            )
            refreshRepoIndex()
        }
    }

    /// Directories the open spaces already sit in. A repo matching one of these
    /// is not offered again — its space is already a palette row.
    var openWorkspacePaths: [String] {
        guard let snapshot else { return [] }
        var paths = snapshot.panes.map(\.cwd)
        paths += snapshot.workspaces.compactMap { $0.worktree?.checkoutPath }
        return paths
    }

    /// Rescans the herd's host for checkouts. Cheap enough to run whenever the
    /// palette opens, so a repo cloned a minute ago is already offered.
    func refreshRepoIndex() {
        let roots = repoRoots
        let depth = repoDepth
        let target = remoteTarget
        let generation = connectionGeneration
        repoScanTask?.cancel()
        repoScanTask = Task { [weak self] in
            let repos = await RepoScanner.scan(
                roots: roots,
                depth: depth,
                remoteTarget: target
            )
            guard !Task.isCancelled else { return }
            guard let self, generation == self.connectionGeneration else { return }
            self.discoveredRepos = repos
        }
    }

    /// Turns a checkout into a space. herdr creates the workspace, its first
    /// tab, and a root pane already inside the repo.
    func openSpace(atPath path: String, label: String) {
        runAction(RepoDiscoveryPlanner.workspaceCreateArguments(path: path, label: label))
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

    /// Test seam: stages a snapshot without a live herd so snapshot-derived
    /// bookkeeping (e.g. close(tab:)'s reopen record) is testable in isolation.
    func adoptSnapshotForTesting(_ newSnapshot: SessionSnapshot) {
        snapshot = newSnapshot
    }

    func close(tab: HerdrTab) {
        guard let record = closedTabRecord(for: tab) else { return }
        guard let arguments = closeTabArguments(tabID: tab.tabID) else { return }
        // The record lands BEFORE any async hop: reopen (⌘⇧T) must always
        // find it, even when the argv capture below is slow, fails, or the
        // connection drops mid-close.
        closedTabs.append(record)
        if closedTabs.count > 10 {
            closedTabs.removeFirst(closedTabs.count - 10)
        }
        // Every agent pane in the tab, by shape leaf when there is one, so a
        // two-agent split reopens both with their original flags.
        let tabPanes = snapshot?.panes.filter { $0.tabID == tab.tabID } ?? []
        let leafOrder: [String] = record.shape == nil
            ? []
            : snapshot?.layouts.first { $0.tabID == tab.tabID }
                .flatMap(PaneLayoutTreeBuilder.build)?.paneIDs ?? []
        let captures: [(paneID: String, kind: AgentLaunchKind, leaf: Int?)] = tabPanes
            .compactMap { pane in
                guard let kind = Self.agentLaunchKind(for: pane) else { return nil }
                return (pane.paneID, kind, leafOrder.firstIndex(of: pane.paneID))
            }
        guard !captures.isEmpty else {
            runAction(arguments)
            return
        }
        let recordID = record.id
        let primaryPaneID = captures.first { $0.kind == record.agentKind }?.paneID
        Task {
            // Capture each agent's command line BEFORE the close kills it, so
            // reopen can bring the session back with all its original flags —
            // but bounded: a slow herd must not wedge the close, and a missed
            // capture only costs the flags, not the reopen.
            let infos = await withTaskGroup(
                of: (String, PaneProcessInfo?).self,
                returning: [String: PaneProcessInfo].self
            ) { group in
                for capture in captures {
                    group.addTask { [weak self] in
                        (capture.paneID, await self?.processInfo(
                            for: capture.paneID,
                            timeout: .seconds(2)
                        ))
                    }
                }
                var results: [String: PaneProcessInfo] = [:]
                for await (paneID, info) in group {
                    if let info { results[paneID] = info }
                }
                return results
            }
            var argvs: [String: [String]] = [:]
            for capture in captures {
                guard let info = infos[capture.paneID],
                      let argv = Self.agentArgv(from: info, kind: capture.kind) else { continue }
                argvs[capture.paneID] = argv
            }
            if let index = closedTabs.lastIndex(where: { $0.id == recordID }) {
                for capture in captures {
                    guard let argv = argvs[capture.paneID] else { continue }
                    if let leaf = capture.leaf {
                        closedTabs[index].shape?.seeds[leaf].agentArgv = argv
                    }
                    if capture.paneID == primaryPaneID {
                        closedTabs[index].agentArgv = argv
                    }
                }
            }
            runAction(arguments)
        }
    }

    /// The argv of the tab's running agent process, when it is recognizably
    /// the agent binary (basename match) — anything murkier reopens with the
    /// safe default instead of replaying an arbitrary command line.
    static func agentArgv(from info: PaneProcessInfo, kind: AgentLaunchKind) -> [String]? {
        let binary = kind.rawValue
        let process = info.foregroundProcesses.first { process in
            guard let first = process.argv.first else { return false }
            return (first as NSString).lastPathComponent == binary
        }
        guard let argv = process?.argv, !argv.isEmpty else { return nil }
        return argv
    }

    /// The shell command that resumes a reopened tab's agent. With a captured
    /// argv, resume carries every original flag and falls back to the same
    /// flags without the resume switch; without one, the bare defaults.
    static func resumeCommand(
        kind: AgentLaunchKind,
        argv: [String]?,
        agentSession: AgentSession? = nil
    ) -> String {
        if agentSession?.agent == kind.rawValue,
           let plan = agentSession?.exactResumePlan(argv: argv) {
            let resume = plan.resumeArgv.map(DroppedPathEscaper.escape)
                .joined(separator: " ")
            let fallback = plan.fallbackArgv.map(DroppedPathEscaper.escape)
                .joined(separator: " ")
            return "\(resume) || \(fallback)"
        }
        guard let argv, !argv.isEmpty,
              (argv[0] as NSString).lastPathComponent == kind.rawValue
        else {
            switch kind {
            case .claude: return "claude --continue || claude"
            case .codex: return "codex resume --last || codex"
            }
        }
        var tokens = argv
        tokens[0] = (tokens[0] as NSString).lastPathComponent
        let escaped = tokens.map { DroppedPathEscaper.escape($0) }
        let base = escaped.joined(separator: " ")
        switch kind {
        case .claude:
            let hasResume = tokens.contains { ["--continue", "-c", "--resume", "-r"].contains($0) }
            return hasResume ? base : "\(base) --continue || \(base)"
        case .codex:
            let flags = escaped.dropFirst().joined(separator: " ")
            let withFlags = flags.isEmpty ? "" : " \(flags)"
            return tokens.contains("resume")
                ? base
                : "codex\(withFlags) resume --last || \(base)"
        }
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
        let agentPane = panes.first { Self.agentLaunchKind(for: $0) != nil }
        let agentKind = agentPane.flatMap(Self.agentLaunchKind)
        return ClosedTabRecord(
            workspaceID: tab.workspaceID,
            cwd: activePane.foregroundCWD ?? activePane.cwd,
            agentKind: agentKind,
            agentSession: agentPane?.agentSession,
            label: tab.label,
            shape: closedTabShape(for: tab, panes: panes)
        )
    }

    /// The tab's full pane arrangement, when it has one worth recording. A
    /// single-pane tab returns nil and reopens through the simpler path.
    private func closedTabShape(for tab: HerdrTab, panes: [Pane]) -> ClosedTabShape? {
        guard panes.count > 1,
              let layout = snapshot?.layouts.first(where: { $0.tabID == tab.tabID }),
              let tree = PaneLayoutTreeBuilder.build(from: layout) else {
            return nil
        }
        let order = tree.paneIDs
        let paneByID = Dictionary(uniqueKeysWithValues: panes.map { ($0.paneID, $0) })
        let seeds = order.compactMap { paneByID[$0] }.map { pane in
            ClosedPaneSeed(
                cwd: pane.foregroundCWD ?? pane.cwd,
                agentKind: Self.agentLaunchKind(for: pane),
                agentSession: pane.agentSession
            )
        }
        // A leaf without a matching pane means the layout and the pane list
        // disagree; rebuilding from that would misplace panes.
        guard seeds.count == order.count else { return nil }
        return ClosedTabShape(
            seeds: seeds,
            steps: TabShapePlanner.steps(for: tree),
            focusedLeaf: order.firstIndex(of: layout.focusedPaneID),
            zoomed: layout.zoomed && order.count > 1
        )
    }

    private static func agentLaunchKind(for pane: Pane) -> AgentLaunchKind? {
        guard let agent = pane.agent?.lowercased() else { return nil }
        if agent.contains("claude") { return .claude }
        if agent.contains("codex") { return .codex }
        return nil
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

    /// The repo a workspace's worktree commands should act on.
    ///
    /// herdr records `worktree` provenance only for workspaces it created
    /// through `worktree create`/`worktree open`. A space opened straight from a
    /// repo path — the palette's repo rows, or any `workspace create --cwd` —
    /// has none, even though it sits in a perfectly good checkout. Its git
    /// status resolves that checkout, which is all the worktree commands need.
    ///
    /// The fallback is local-only: on a remote herd rai cannot stat the
    /// checkout, so no git status arrives. Provenance-carrying workspaces still
    /// work there, because that field comes from the snapshot.
    func worktreeContext(for workspace: Workspace) -> WorktreeRepositoryContext? {
        if let worktree = workspace.worktree {
            return WorktreeRepositoryContext(
                repoName: worktree.repoName,
                checkoutPath: worktree.checkoutPath
            )
        }
        guard let status = gitStatus(for: workspace) else { return nil }
        return WorktreeRepositoryContext(
            repoName: RepoDiscoveryPlanner.name(for: status.checkoutPath),
            checkoutPath: status.checkoutPath
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

    /// Relocates a whole tab into another workspace. herdr's tab.move cannot
    /// cross spaces, so this is a pane.move sequence (see TabMovePlanner);
    /// `insertBeforeTabID` then reorders the landing tab to where the drop
    /// happened — omitted, the tab lands at the end of the target space.
    func moveTab(
        _ tabID: String,
        toWorkspaceID targetWorkspaceID: String,
        insertBeforeTabID: String? = nil
    ) {
        guard let snapshot,
              let tab = snapshot.tabs.first(where: { $0.tabID == tabID }),
              tab.workspaceID != targetWorkspaceID,
              snapshot.workspaces.contains(where: {
                  $0.workspaceID == targetWorkspaceID
              }) else {
            return
        }
        let layout = snapshot.layouts.first { $0.tabID == tabID }
        guard let plan = TabMovePlanner.plan(
            tab: tab,
            panes: snapshot.panes,
            layout: layout
        ) else {
            return
        }
        // Index within the target workspace's tab list, the same coordinate
        // space the same-space reorder feeds tab.move.
        let insertIndex = insertBeforeTabID.flatMap { before in
            snapshot.tabs
                .filter { $0.workspaceID == targetWorkspaceID }
                .firstIndex { $0.tabID == before }
        }
        performTabMove(
            plan: plan,
            leadDestination: .newTab(
                workspaceID: targetWorkspaceID,
                label: plan.carriedLabel
            ),
            insertIndex: insertIndex,
            unzoomFirst: layout?.zoomed == true
        )
    }

    /// Moves a tab into a brand-new workspace of its own.
    func moveTabToNewWorkspace(_ tabID: String) {
        guard let snapshot,
              let tab = snapshot.tabs.first(where: { $0.tabID == tabID }) else {
            return
        }
        let layout = snapshot.layouts.first { $0.tabID == tabID }
        guard let plan = TabMovePlanner.plan(
            tab: tab,
            panes: snapshot.panes,
            layout: layout
        ) else {
            return
        }
        performTabMove(
            plan: plan,
            leadDestination: .newWorkspace(label: nil, tabLabel: plan.carriedLabel),
            insertIndex: nil,
            unzoomFirst: layout?.zoomed == true
        )
    }

    /// Moves one pane into a new sidebar tab.
    func movePaneToNewTab(
        _ paneID: String,
        toWorkspaceID targetWorkspaceID: String,
        insertBeforeTabID: String? = nil
    ) {
        guard let snapshot,
              let pane = snapshot.panes.first(where: { $0.paneID == paneID }),
              snapshot.workspaces.contains(where: {
                  $0.workspaceID == targetWorkspaceID
              }) else {
            return
        }
        let sourceLayout = snapshot.layouts.first { $0.tabID == pane.tabID }
        let targetTabs = snapshot.tabs.filter {
            $0.workspaceID == targetWorkspaceID
        }
        let sourceIndex = targetTabs.firstIndex {
            $0.tabID == pane.tabID
        }
        let insertIndex = insertBeforeTabID.flatMap { before in
            targetTabs.firstIndex { $0.tabID == before }
        }
        let label = displayTitle(for: pane)
        let client = client
        let generation = connectionGeneration

        Task {
            do {
                if sourceLayout?.zoomed == true {
                    try await client.unzoomPane(paneID)
                }
                let outcome = try await client.movePane(
                    paneID,
                    to: .newTab(
                        workspaceID: targetWorkspaceID,
                        label: label
                    ),
                    focus: true
                )
                if let newTabID = outcome.createdTab?.tabID,
                   var destinationIndex = insertIndex {
                    if outcome.closedTabID == pane.tabID,
                       let sourceIndex,
                       sourceIndex < destinationIndex {
                        destinationIndex -= 1
                    }
                    try await client.moveTab(
                        newTabID,
                        insertIndex: destinationIndex
                    )
                }
                guard generation == connectionGeneration else { return }
                selectedPaneID = outcome.pane.paneID
                await refreshSnapshot(keepSelection: true)
            } catch {
                if generation == connectionGeneration {
                    connectionState = .disconnected(error.localizedDescription)
                }
            }
        }
    }

    private func performTabMove(
        plan: TabMovePlanner.Plan,
        leadDestination: PaneMoveDestination,
        insertIndex: Int?,
        unzoomFirst: Bool
    ) {
        let client = client
        let generation = connectionGeneration
        // Crossing workspaces rewrites pane ids, so a selection inside the
        // moved tab must follow the ids the move responses hand back.
        let selectedBeforeMove = selectedPaneID
        Task {
            do {
                var remappedSelection: String?
                // A zoomed source tab makes pane.move a silent no-op
                // (changed: false, reason: zoomed_tab) — un-zoom first.
                if unzoomFirst {
                    try await client.unzoomPane(plan.leadPaneID)
                }
                let outcome = try await client.movePane(
                    plan.leadPaneID,
                    to: leadDestination
                )
                if plan.leadPaneID == selectedBeforeMove {
                    remappedSelection = outcome.pane.paneID
                }
                if let landingTabID = outcome.createdTab?.tabID {
                    for paneID in plan.followerPaneIDs {
                        let followed = try await client.movePane(
                            paneID,
                            to: .tab(tabID: landingTabID, split: .right)
                        )
                        if paneID == selectedBeforeMove {
                            remappedSelection = followed.pane.paneID
                        }
                    }
                    if let insertIndex {
                        try await client.moveTab(landingTabID, insertIndex: insertIndex)
                    }
                }
                guard generation == connectionGeneration else { return }
                if let remappedSelection, selectedPaneID == selectedBeforeMove {
                    selectedPaneID = remappedSelection
                }
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
        scheduleFlush(generation: generation)
    }

    private func scheduleFlush(generation: UUID) {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !Task.isCancelled else { return }
            await self.flushEvents(generation: generation)
        }
    }

    /// Whether a herdr event implies the session's structure changed and the
    /// snapshot must be re-fetched. Output rides on `pane.updated`: protocol 16
    /// cannot subscribe to `pane.output_changed`, so `events()` substitutes it —
    /// treating `pane.updated` as structural made every output burst refresh
    /// the full snapshot, spawn a herdr CLI, and re-render the whole UI while
    /// the user typed.
    static func isStructuralEvent(_ name: String) -> Bool {
        name != "pane.output_changed" && name != "pane.updated"
    }

    private func flushEvents(generation: UUID) async {
        guard generation == connectionGeneration else { return }
        let events = pendingEvents
        pendingEvents.removeAll(keepingCapacity: true)
        guard !events.isEmpty else {
            flushTask = nil
            return
        }
        bridgeServer.relay(events: events)

        // The terminal content itself is rendered by each pane's attach process,
        // so we only need to re-snapshot on structural changes (create/close/move/
        // focus/status) — never on raw output.
        if events.contains(where: { Self.isStructuralEvent($0.name) }) {
            trailingRefreshTask?.cancel()
            trailingRefreshTask = nil
            await refreshSnapshot(keepSelection: true)
        } else {
            scheduleTrailingRefresh(generation: generation)
        }
        // Cleared only after the refresh completes: a flush scheduled mid-refresh
        // would otherwise stack a second snapshot fetch on top of the running one.
        flushTask = nil
        if !pendingEvents.isEmpty {
            scheduleFlush(generation: generation)
        }
    }

    /// Output-only flushes still deserve an eventual snapshot (pane titles and
    /// cwd ride on it), just not one per burst: coalesce to at most one refresh
    /// every few seconds while output streams.
    private func scheduleTrailingRefresh(generation: UUID) {
        guard trailingRefreshTask == nil else { return }
        trailingRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            self.trailingRefreshTask = nil
            guard generation == self.connectionGeneration else { return }
            await self.refreshSnapshot(keepSelection: true)
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
            restartGitStatusLoop(generation: generation)
            terminalPool.retain(
                terminalIDs: Set(newSnapshot.panes.map(\.terminalID))
            )
            connectionState = .connected(
                version: newSnapshot.version,
                protocolVersion: newSnapshot.protocol
            )
            // Once per connection, not once per snapshot: this spawns a herdr
            // CLI process, and snapshot refreshes ride the event stream.
            if pluginActionsGeneration != generation {
                pluginActionsGeneration = generation
                await refreshPluginActions(generation: generation)
            }
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
            refreshBackgroundWork()
        } catch {
            if generation == connectionGeneration {
                connectionState = .disconnected(error.localizedDescription)
            }
        }
    }

    /// Snapshot changes restart the loop. The cache limits Git work to one
    /// serial pass every 30 seconds and reads new checkout paths at once.
    private func restartGitStatusLoop(generation: UUID) {
        gitStatusTask?.cancel()
        guard remoteTarget == nil else {
            gitStatusTask = nil
            workspaceGitStatuses = [:]
            return
        }

        gitStatusTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, generation == connectionGeneration {
                guard let snapshot else { return }
                let paths = WorkspaceSidebar.checkoutPaths(in: snapshot)
                let statuses = await workspaceGitStatusCache.statuses(for: paths)
                guard !Task.isCancelled, generation == connectionGeneration else { return }
                workspaceGitStatuses = statuses
                try? await Task.sleep(for: .seconds(30))
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
        newTab(inWorkspace: workspace, afterTabID: selectedTabID)
    }
    /// herdr appends created tabs at the end of the space; with an anchor the
    /// new tab is reordered to sit right after it (browser-style).
    func newTab(inWorkspace workspaceID: String, afterTabID: String? = nil) {
        let insertIndex = NewTabPlacement.insertIndex(
            tabs: snapshot?.tabs ?? [],
            workspaceID: workspaceID,
            afterTabID: afterTabID
        )
        guard let insertIndex else {
            runAction(["tab", "create", "--workspace", workspaceID, "--focus"])
            return
        }
        let client = client
        let generation = connectionGeneration
        Task {
            let output = await runHerdrCapture(
                ["tab", "create", "--workspace", workspaceID, "--focus"]
            )
            guard generation == connectionGeneration else { return }
            if let data = output?.data(using: .utf8),
               let response = try? JSONDecoder().decode(
                   TabCreateResponse.self,
                   from: data
               ) {
                // Best-effort: a failed reorder still leaves a usable tab at
                // the end of the space.
                try? await client.moveTab(
                    response.result.tab.tabID,
                    insertIndex: insertIndex
                )
            }
            guard generation == connectionGeneration else { return }
            await refreshSnapshot(keepSelection: false)
        }
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
    func closePane(_ paneID: String? = nil) {
        guard let pane = paneID ?? selectedPaneID else { return }
        // Closing a tab's only pane kills the tab either way; the direct pane
        // path just loses the ⌘⇧T record. Route it through close(tab:) so the
        // tab is recorded for reopen, whichever surface asked — the pane ✕,
        // the palette, or the keyboard.
        if let snapshot,
           let closing = snapshot.panes.first(where: { $0.paneID == pane }),
           snapshot.panes.filter({ $0.tabID == closing.tabID }).count == 1,
           let tab = snapshot.tabs.first(where: { $0.tabID == closing.tabID }) {
            close(tab: tab)
            return
        }
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

    func setAgentOverride(
        paneID: String,
        agent: AgentAuthorityAgent,
        state: AgentAuthorityState
    ) {
        let arguments = AgentAuthorityCLI.reportArguments(
            paneID: paneID,
            agent: agent,
            state: state
        )
        let client = client
        let generation = connectionGeneration
        Task {
            guard let context = await agentAuthorityContext(for: paneID),
                  context.paneID == paneID,
                  context.reportAvailability == .available,
                  generation == connectionGeneration else {
                return
            }
            _ = await runHerdr(arguments)
            guard generation == connectionGeneration else { return }
            await refreshSnapshot(
                keepSelection: true,
                client: client,
                generation: generation
            )
        }
    }

    func agentAuthorityContext(for paneID: String) async -> AgentAuthorityContext? {
        guard let output = await runHerdrCapture(["pane", "get", paneID]) else {
            return nil
        }
        return AgentAuthorityContextParser.parse(output)
    }

    func clearAgentOverride(paneID: String) {
        let socketPath = activeSocketPath
        let client = client
        let generation = connectionGeneration
        Task {
            // Herdr exposes clear-authority through its socket API, but not its CLI.
            try? await AgentAuthorityRPC.clearOverride(
                socketPath: socketPath,
                paneID: paneID
            )
            guard generation == connectionGeneration else { return }
            await refreshSnapshot(
                keepSelection: true,
                client: client,
                generation: generation
            )
        }
    }

    func releaseAgent(paneID: String, agent: String?) {
        guard let agent,
              let arguments = AgentAuthorityCLI.releaseArguments(
                  paneID: paneID,
                  agent: agent
              ) else {
            return
        }
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

    /// paneID → live background shells/monitors the pane's Claude session has
    /// registered (see BackgroundWorkParser). Refreshed with the snapshot,
    /// throttled; drives the sidebar badge and gates "Finished" notifications.
    @Published private(set) var backgroundWork: [String: [AgentBackgroundTask]] = [:]
    private var lastBackgroundWorkRefresh = Date.distantPast

    /// One system-wide ps listing (pid, ppid, command).
    nonisolated private static func psRows() -> [BackgroundWorkParser.PSRow] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Ao", "pid=,ppid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 3, let pid = Int(parts[0]), let ppid = Int(parts[1]) else {
                return nil
            }
            return .init(pid: pid, ppid: ppid, command: String(parts[2]))
        }
    }

    /// Live check for one pane — used before posting a "Finished" notification:
    /// a session with background work pending isn't finished, just waiting.
    func pendingBackgroundWork(forPane paneID: String) async -> [AgentBackgroundTask] {
        guard let claude = await claudeInfo(forPane: paneID) else { return [] }
        let rows = await Task.detached { Self.psRows() }.value
        let shells = BackgroundWorkParser.backgroundShells(psRows: rows, claudePID: Int(claude.pid))
        let async = await Task.detached {
            Self.transcriptPendingWork(claudeCmdline: claude.cmdline, claudeCWD: claude.cwd)
        }.value
        return shells + async
    }

    /// Transcript scans are expensive (multi-MB jsonl reads + JSON parsing) and
    /// transcripts only grow — cache results keyed by (path, size, mtime) so an
    /// unchanged file costs one stat instead of a re-read. In steady state an
    /// idle herd makes every refresh nearly free.
    private final class TranscriptCache: @unchecked Sendable {
        struct Signature: Equatable {
            let size: UInt64
            let mtime: Date
        }
        private let lock = NSLock()
        private var entries: [String: (Signature, Any)] = [:]

        func value<T>(for key: String, signature: Signature) -> T? {
            lock.lock(); defer { lock.unlock() }
            guard let (cached, value) = entries[key], cached == signature else { return nil }
            return value as? T
        }

        func store(_ value: Any, for key: String, signature: Signature) {
            lock.lock(); defer { lock.unlock() }
            entries[key] = (signature, value)
        }

        /// Time-based entries, for work that is expensive AND tolerant of
        /// staleness (human descriptions of already-running tasks).
        private var timed: [String: (Date, Any)] = [:]

        func timedValue<T>(for key: String, ttl: TimeInterval) -> T? {
            lock.lock(); defer { lock.unlock() }
            guard let (stamp, value) = timed[key], Date().timeIntervalSince(stamp) < ttl else {
                return nil
            }
            return value as? T
        }

        func storeTimed(_ value: Any, for key: String) {
            lock.lock(); defer { lock.unlock() }
            timed[key] = (Date(), value)
        }

        static func signature(of path: String) -> Signature? {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
                return nil
            }
            return Signature(
                size: (attrs[.size] as? NSNumber)?.uint64Value ?? 0,
                mtime: attrs[.modificationDate] as? Date ?? .distantPast
            )
        }
    }

    private static let transcriptCache = TranscriptCache()

    /// Recovers the session's own human descriptions for background tasks from
    /// the Claude Code transcript: every backgrounded Bash tool call records a
    /// `description` alongside its `command`. Matched by whitespace-insensitive
    /// command content. `cwd` is the claude process's working directory, which
    /// names the transcript project folder.
    nonisolated private static func transcriptSummaries(
        for tasks: [AgentBackgroundTask],
        claudeCWD: String
    ) -> [AgentBackgroundTask] {
        guard !tasks.isEmpty else { return tasks }
        var slug = claudeCWD
        for ch in ["/", ".", "_", " "] {
            slug = slug.replacingOccurrences(of: ch, with: "-")
        }
        let dir = NSHomeDirectory() + "/.claude/projects/" + slug
        // TIME-based cache, deliberately, checked BEFORE any filesystem work:
        // the live session's transcript changes every few seconds, so a content
        // signature would never hit, and even the directory listing + mtime
        // sort showed up in profiles (a stat per comparison). Descriptions
        // belong to tasks that ALREADY started, so five-minute staleness is
        // harmless — a newer task shows its command until the next harvest.
        let cacheKey = "described:\(dir)"
        var described: [(command: String, description: String)] = []
        if let cached: [[String]] = Self.transcriptCache.timedValue(for: cacheKey, ttl: 300) {
            described = cached.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
            guard !described.isEmpty else { return tasks }
            return applyDescriptions(described, to: tasks)
        }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return tasks }
        // Stat each candidate ONCE, then sort — newest last so fresher
        // descriptions win.
        let files = names.filter { $0.hasSuffix(".jsonl") }
            .compactMap { name -> (path: String, mtime: Date)? in
                let path = dir + "/" + name
                guard let attrs = try? fm.attributesOfItem(atPath: path) else { return nil }
                return (path, attrs[.modificationDate] as? Date ?? .distantPast)
            }
            .sorted { $0.mtime < $1.mtime }
            .suffix(6)
            .map(\.path)
        guard !files.isEmpty else { return tasks }
        do {
            let grep = Process()
            grep.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
            // Backgrounded Bash calls AND Monitor tool calls both carry a
            // command + human description in the transcript.
            grep.arguments = ["-hE", "\"run_in_background\":true|\"name\":\"Monitor\""] + files
            let pipe = Pipe()
            grep.standardOutput = pipe
            grep.standardError = FileHandle.nullDevice
            guard (try? grep.run()) != nil else { return tasks }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            grep.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8) else { return tasks }

            for line in text.split(separator: "\n") {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) else { continue }
                collectBackgroundBashInputs(obj, into: &described)
            }
            Self.transcriptCache.storeTimed(
                described.map { [$0.command, $0.description] },
                for: cacheKey
            )
        }
        guard !described.isEmpty else { return tasks }
        return applyDescriptions(described, to: tasks)
    }

    nonisolated private static func applyDescriptions(
        _ described: [(command: String, description: String)],
        to tasks: [AgentBackgroundTask]
    ) -> [AgentBackgroundTask] {
        tasks.map { task in
            var task = task
            for entry in described.reversed()
            where BackgroundWorkParser.matches(definition: task.definition, command: entry.command) {
                task.summary = entry.description
                break
            }
            return task
        }
    }

    nonisolated private static func collectBackgroundBashInputs(
        _ object: Any,
        into result: inout [(command: String, description: String)]
    ) {
        if let dict = object as? [String: Any] {
            let name = dict["name"] as? String
            if name == "Bash" || name == "Monitor",
               let input = dict["input"] as? [String: Any],
               name == "Monitor" || input["run_in_background"] as? Bool == true,
               let command = input["command"] as? String,
               let description = input["description"] as? String {
                result.append((command, description))
            }
            for value in dict.values { collectBackgroundBashInputs(value, into: &result) }
        } else if let array = object as? [Any] {
            for value in array { collectBackgroundBashInputs(value, into: &result) }
        }
    }

    /// Transcript-recovered async work that has no observable process:
    /// subagents and workflows run inside the claude process itself, so the
    /// session transcript is the only place their lifecycle shows. Session
    /// file: the `--resume <uuid>` in claude's argv when present, else the
    /// newest transcript in the project folder for claude's cwd.
    nonisolated private static func transcriptPendingWork(
        claudeCmdline: String,
        claudeCWD: String
    ) -> [AgentBackgroundTask] {
        var slug = claudeCWD
        for ch in ["/", ".", "_", " "] {
            slug = slug.replacingOccurrences(of: ch, with: "-")
        }
        let dir = NSHomeDirectory() + "/.claude/projects/" + slug
        let fm = FileManager.default

        var file: String?
        if let range = claudeCmdline.range(
            of: "--resume [0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
            options: .regularExpression
        ) {
            let uuid = claudeCmdline[range].dropFirst("--resume ".count)
            file = dir + "/" + uuid + ".jsonl"
        } else if let names = try? fm.contentsOfDirectory(atPath: dir) {
            file = names.filter { $0.hasSuffix(".jsonl") }
                .compactMap { name -> (path: String, mtime: Date)? in
                    let path = dir + "/" + name
                    guard let attrs = try? fm.attributesOfItem(atPath: path) else { return nil }
                    return (path, attrs[.modificationDate] as? Date ?? .distantPast)
                }
                .max { $0.mtime < $1.mtime }?
                .path
        }
        guard let file else { return [] }
        // Exact signature hit first (idle sessions: free). For LIVE sessions
        // the file churns every few seconds and the signature never matches —
        // floor those to one parse per 45s; pending async work does not
        // meaningfully change faster.
        if let signature = TranscriptCache.signature(of: file),
           let cached: [AgentBackgroundTask] = Self.transcriptCache.value(
               for: "pending:" + file, signature: signature
           ) {
            return cached
        }
        if let recent: [AgentBackgroundTask] = Self.transcriptCache.timedValue(
            for: "pending-ttl:" + file, ttl: 45
        ) {
            return recent
        }
        guard let handle = FileHandle(forReadingAtPath: file) else { return [] }
        defer { try? handle.close() }
        // Tail window: recent enough for anything still in flight.
        let tailBytes: UInt64 = 1_536 * 1024
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > tailBytes ? size - tailBytes : 0)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if size > tailBytes, !lines.isEmpty { lines.removeFirst() }   // partial first line

        let pending = TranscriptWorkParser.pendingAsyncWork(jsonlLines: lines)
            // Shells/monitors are covered live by process detection; the
            // transcript contributes only the process-less kinds.
            .filter { $0.kind == .subagent || $0.kind == .workflow }
            .map { work in
                AgentBackgroundTask(
                    pid: -abs(work.toolUseID.hashValue % 1_000_000),
                    definition: "[\(work.kind.rawValue)] \(work.description)",
                    summary: "[\(work.kind.rawValue)] \(work.description)"
                )
            }
        if let signature = TranscriptCache.signature(of: file) {
            Self.transcriptCache.store(pending, for: "pending:" + file, signature: signature)
        }
        Self.transcriptCache.storeTimed(pending, for: "pending-ttl:" + file)
        return pending
    }

    /// paneID → its claude process (pid, cmdline, cwd), cached because a
    /// pane's claude pid is stable for its lifetime. Validated per use with a
    /// zero-signal kill(2); on miss the herdr CLI re-resolves. This removes
    /// ~one process spawn per pane per refresh cycle.
    private var claudeInfoCache: [String: (pid: Int32, cmdline: String, cwd: String)] = [:]

    private func claudeInfo(forPane paneID: String) async -> (pid: Int32, cmdline: String, cwd: String)? {
        if let cached = claudeInfoCache[paneID], kill(cached.pid, 0) == 0 {
            return cached
        }
        claudeInfoCache[paneID] = nil
        guard let info = await processInfo(for: paneID) else { return nil }
        let processes = info.foregroundProcesses.map { (pid: $0.pid, cmdline: $0.cmdline) }
        guard let claudePID = BackgroundWorkParser.claudePID(inCommandLines: processes),
              let claude = info.foregroundProcesses.first(where: { $0.pid == claudePID }) else {
            return nil
        }
        let resolved = (pid: Int32(claude.pid), cmdline: claude.cmdline, cwd: claude.cwd)
        claudeInfoCache[paneID] = resolved
        return resolved
    }

    /// Refreshes the sidebar's background-work map for every pane (throttled).
    func refreshBackgroundWork(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastBackgroundWorkRefresh) > 20 else { return }
        lastBackgroundWorkRefresh = Date()
        guard let snapshot else { return }
        let paneIDs = snapshot.panes.map(\.paneID)
        let generation = connectionGeneration
        Task {
            let rows = await Task.detached { Self.psRows() }.value
            var result: [String: [AgentBackgroundTask]] = [:]
            for paneID in paneIDs {
                guard let claude = await claudeInfo(forPane: paneID) else { continue }
                let shellTasks = BackgroundWorkParser.backgroundShells(
                    psRows: rows, claudePID: Int(claude.pid)
                )
                let tasks = await Task.detached {
                    var enriched = shellTasks.isEmpty
                        ? shellTasks
                        : Self.transcriptSummaries(for: shellTasks, claudeCWD: claude.cwd)
                    enriched += Self.transcriptPendingWork(
                        claudeCmdline: claude.cmdline, claudeCWD: claude.cwd
                    )
                    return enriched
                }.value
                if !tasks.isEmpty { result[paneID] = tasks }
            }
            guard generation == connectionGeneration else { return }
            // Only publish on change: an unchanged map re-rendering the whole
            // sidebar (and re-broadcasting to phones) every cycle is pure churn.
            if backgroundWork != result {
                backgroundWork = result
                bridgeServer.relay(backgroundWork: result)
            }
        }
    }

    func backgroundWork(forTab tabID: String) -> [AgentBackgroundTask] {
        guard let snapshot else { return [] }
        return snapshot.panes
            .filter { $0.tabID == tabID }
            .flatMap { backgroundWork[$0.paneID] ?? [] }
    }

    /// Opens the explanation sheet listing a tab's background work definitions.
    func showBackgroundWork(forTab tab: HerdrTab) {
        let tasks = backgroundWork(forTab: tab.tabID)
        guard !tasks.isEmpty else { return }
        let text = tasks
            .map { task in
                let heading = task.pid > 0
                    ? "▸ \(task.displaySummary)  (pid \(task.pid))"
                    : "▸ \(task.displaySummary)"
                return task.definition == task.summary
                    ? heading
                    : heading + "\n\n\(task.definition)"
            }
            .joined(separator: "\n\n————————————\n\n")
        statusExplanation = StatusExplanation(
            id: UUID(),
            title: "Background work — the session is waiting on this",
            text: text
        )
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

    /// Bounded process-info lookup: gives up (and terminates the CLI call)
    /// after `timeout`, so callers on an interactive path never wedge on a
    /// slow herd.
    func processInfo(
        for paneID: String,
        timeout: Duration
    ) async -> PaneProcessInfo? {
        await withTaskGroup(of: PaneProcessInfo?.self) { group in
            group.addTask { await self.processInfo(for: paneID) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            // Cancelling the loser terminates the herdr subprocess (see
            // runHerdrCapture), so the group's implicit wait stays short.
            group.cancelAll()
            return first
        }
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
        // The companion's "New workspace" choice must actually create one:
        // `agent start` without --workspace lands in the *currently focused*
        // workspace, dropping surprise agents into whatever the user is
        // looking at.
        var targetWorkspace = workspaceID
        if targetWorkspace == nil {
            var createArgs = ["workspace", "create", "--no-focus"]
            if let cwd {
                createArgs += ["--cwd", cwd]
            }
            guard let output = await runHerdrCapture(createArgs),
                  let created = Self.workspaceID(fromCreateOutput: output) else {
                return false
            }
            targetWorkspace = created
        }
        return await runHerdr(
            PaneActionPlanner.agentStartArguments(
                name: Self.defaultAgentName(kind),
                executable: kind.rawValue,
                workspaceID: targetWorkspace,
                cwd: cwd
            )
        )
    }

    static func workspaceID(fromCreateOutput output: String) -> String? {
        guard let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let rootPane = result["root_pane"] as? [String: Any],
              let workspaceID = rootPane["workspace_id"] as? String
        else { return nil }
        return workspaceID
    }

    /// Companion "open a Terminal": a plain shell pane, no agent. herdr seeds
    /// a default shell pane in every new workspace and tab, so this is a
    /// create, not an `agent start`.
    func createTerminalFromBridge(workspaceID: String?, cwd: String?) async -> Bool {
        var arguments: [String]
        if let workspaceID {
            arguments = ["tab", "create", "--workspace", workspaceID]
        } else {
            arguments = ["workspace", "create"]
        }
        if let cwd {
            arguments += ["--cwd", cwd]
        }
        arguments.append("--no-focus")
        return await runHerdr(arguments)
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

    /// Workspace rename requested by the phone. The phone confirms
    /// destructive/renaming intents on its side; this applies directly.
    func renameWorkspaceFromBridge(workspaceID: String, label rawLabel: String) {
        let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return }
        runAction(["workspace", "rename", workspaceID, label], followFocus: false)
    }

    /// Workspace close requested by the phone (already confirmed there).
    func closeWorkspaceFromBridge(workspaceID: String) {
        runAction(["workspace", "close", workspaceID], followFocus: false)
    }

    /// Broadcast text to every pane in a tab, for the phone's compose bar.
    func broadcastFromBridge(tabID: String, text: String) {
        guard !text.isEmpty, let snapshot else { return }
        let paneIDs = snapshot.panes.filter { $0.tabID == tabID }.map(\.paneID)
        guard !paneIDs.isEmpty else { return }
        Task {
            for paneID in paneIDs {
                guard await runHerdr(["pane", "send-text", paneID, text]) else { continue }
                _ = await runHerdr(["pane", "send-keys", paneID, "Enter"])
            }
        }
    }

    /// The session list in the bridge's wire shape.
    func bridgeSessionList() -> [BridgeSessionInfo] {
        sessions.map {
            BridgeSessionInfo(
                name: $0.name,
                isRunning: $0.isRunning,
                isCurrent: isCurrentSession($0)
            )
        }
    }

    /// Switch the herd the Mac (and therefore the phone) is attached to.
    func selectSessionFromBridge(named name: String) {
        guard let session = sessions.first(where: { $0.name == name }) else { return }
        switchSession(session)
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
        // With a recorded shape, the tab's first pane is the layout tree's
        // first leaf — its cwd seeds the created tab; the active pane's cwd
        // only drives the single-pane path.
        let rootCwd = record.shape?.seeds.first?.cwd ?? record.cwd
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
                "--cwd", rootCwd,
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
                "--cwd", rootCwd,
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
                    "--cwd", rootCwd,
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
        if let shape = record.shape, shape.seeds.count > 1,
           let rootPaneID = snapshot?.panes.first(where: {
               $0.tabID == reopenedTab.tabID
           })?.paneID {
            await rebuild(shape, rootPaneID: rootPaneID)
        } else if let agentKind = record.agentKind, record.canResumeAgent {
            // Prefer herdr's exact session id. Older servers fall back to each
            // client's cwd-scoped recent session lookup.
            let resumeCommand = Self.resumeCommand(
                kind: agentKind,
                argv: record.agentArgv,
                agentSession: record.agentSession
            )
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
            ] + PaneActionPlanner.shellFallbackArgv(resumeCommand))
            if let defaultPaneID {
                _ = await runHerdr(["pane", "close", defaultPaneID])
            }
        } else {
            _ = await runHerdr(["tab", "focus", reopenedTab.tabID])
        }
        await refreshSnapshot(keepSelection: false)
    }

    private struct PaneSplitResponse: Decodable {
        struct Result: Decodable {
            let pane: PaneRef
        }
        struct PaneRef: Decodable {
            let paneID: String
            enum CodingKeys: String, CodingKey {
                case paneID = "pane_id"
            }
        }
        let result: Result
    }

    /// Recreates a closed tab's splits, per-pane cwds, and per-pane agents on
    /// top of the fresh tab's root pane. Best effort throughout: a failed
    /// split skips its subtree's panes rather than aborting the reopen.
    private func rebuild(_ shape: ClosedTabShape, rootPaneID: String) async {
        var paneIDs: [Int: String] = [0: rootPaneID]
        for step in shape.steps {
            guard let anchor = paneIDs[step.anchorLeaf],
                  let output = await runHerdrCapture([
                      "pane", "split", anchor,
                      "--direction", step.direction.rawValue,
                      "--ratio", String(format: "%.4f", step.ratio),
                      "--cwd", shape.seeds[step.newLeaf].cwd,
                      "--no-focus",
                  ]),
                  let data = output.data(using: .utf8),
                  let response = try? JSONDecoder().decode(
                      PaneSplitResponse.self,
                      from: data
                  ) else {
                continue
            }
            paneIDs[step.newLeaf] = response.result.pane.paneID
        }

        let agentLeaves = shape.seeds.enumerated().filter { $0.element.canResumeAgent }
        if !agentLeaves.isEmpty {
            // The split panes' shells need a beat to reach a prompt before a
            // typed resume command lands in the pty.
            try? await Task.sleep(for: .milliseconds(400))
            for (leaf, seed) in agentLeaves {
                guard let kind = seed.agentKind, let paneID = paneIDs[leaf] else { continue }
                let resume = Self.resumeCommand(
                    kind: kind,
                    argv: seed.agentArgv,
                    agentSession: seed.agentSession
                )
                _ = await runHerdr(["pane", "run", paneID, resume])
            }
        }

        if let focusedLeaf = shape.focusedLeaf, let paneID = paneIDs[focusedLeaf] {
            if shape.zoomed {
                _ = await runHerdr(["pane", "zoom", paneID, "--on"])
            }
            try? await client.focusPane(paneID)
        }
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

    func preparePluginInstall(
        source: String,
        reference: String
    ) async -> HerdrPluginInstallPreview {
        guard remoteTarget == nil else {
            return HerdrPluginInstallPreview(
                canConfirm: false,
                output: "Plugin install is available only for a local Herdr server."
            )
        }
        guard let sourceParts = Self.pluginSourceParts(source) else {
            return HerdrPluginInstallPreview(
                canConfirm: false,
                output: "Use owner/repository[/subdirectory...] shorthand."
            )
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rai-plugin-preview-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: false
            )
        } catch {
            return HerdrPluginInstallPreview(
                canConfirm: false,
                output: error.localizedDescription
            )
        }
        var keepsTemporaryDirectory = false
        defer {
            if !keepsTemporaryDirectory {
                try? FileManager.default.removeItem(at: temporaryDirectory)
            }
        }

        let initialized = await runExternalResult(
            "/usr/bin/git",
            ["init", "--quiet", temporaryDirectory.path]
        )
        guard initialized.succeeded else {
            return pluginPreviewFailure(initialized)
        }
        let addedRemote = await runExternalResult(
            "/usr/bin/git",
            [
                "-C", temporaryDirectory.path,
                "remote", "add", "origin", sourceParts.remoteURL,
            ]
        )
        guard addedRemote.succeeded else {
            return pluginPreviewFailure(addedRemote)
        }
        let fetched = await runExternalResult(
            "/usr/bin/git",
            [
                "-C", temporaryDirectory.path,
                "fetch", "--quiet", "--depth", "1", "origin",
                reference.isEmpty ? "HEAD" : reference,
            ]
        )
        guard fetched.succeeded else {
            return pluginPreviewFailure(fetched)
        }
        let resolved = await runExternalResult(
            "/usr/bin/git",
            [
                "-C", temporaryDirectory.path,
                "rev-parse", "FETCH_HEAD",
            ]
        )
        let commit = resolved.standardOutput.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard resolved.succeeded, !commit.isEmpty else {
            return pluginPreviewFailure(resolved)
        }
        let checkedOut = await runExternalResult(
            "/usr/bin/git",
            [
                "-C", temporaryDirectory.path,
                "checkout", "--quiet", "--detach", "FETCH_HEAD",
            ]
        )
        guard checkedOut.succeeded else {
            return pluginPreviewFailure(checkedOut)
        }
        let resolvedRoot = temporaryDirectory.resolvingSymlinksInPath()
            .standardizedFileURL.path
        let manifestURL = temporaryDirectory
            .appendingPathComponent(sourceParts.manifestPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard manifestURL.path.hasPrefix(resolvedRoot + "/"),
              let manifest = try? String(
                  contentsOf: manifestURL,
                  encoding: .utf8
              ) else {
            return HerdrPluginInstallPreview(
                canConfirm: false,
                output: "The plugin manifest is missing or leaves its checkout."
            )
        }

        pendingPluginInstall = PendingHerdrPluginInstall(
            source: source,
            resolvedCommit: commit,
            socketPath: activeSocketPath,
            temporaryDirectory: temporaryDirectory
        )
        keepsTemporaryDirectory = true
        return HerdrPluginInstallPreview(
            canConfirm: true,
            output: """
                Source: \(source)
                Resolved commit: \(commit)

                \(sourceParts.manifestPath):
                \(manifest.trimmingCharacters(in: .whitespacesAndNewlines))
                """
        )
    }

    func confirmPluginInstall() async -> String {
        guard let pending = pendingPluginInstall else {
            return "No plugin install is waiting for confirmation."
        }
        guard Self.pathsMatch(pending.socketPath, activeSocketPath) else {
            try? FileManager.default.removeItem(
                at: pending.temporaryDirectory
            )
            pendingPluginInstall = nil
            return "Plugin install cancelled because the active Herdr session changed."
        }
        let arguments = [
            "plugin", "install", pending.source,
            "--ref", pending.resolvedCommit,
            "--yes",
        ]
        try? FileManager.default.removeItem(at: pending.temporaryDirectory)
        pendingPluginInstall = nil
        return await commandOutput(
            arguments,
            fallback: "Herdr installed the plugin."
        )
    }

    func cancelPluginInstall() async {
        guard let pending = pendingPluginInstall else { return }
        try? FileManager.default.removeItem(at: pending.temporaryDirectory)
        pendingPluginInstall = nil
    }

    private func pluginPreviewFailure(
        _ result: HerdrCommandResult
    ) -> HerdrPluginInstallPreview {
        HerdrPluginInstallPreview(
            canConfirm: false,
            output: result.errorOutput.isEmpty
                ? "Unable to read the plugin source."
                : result.errorOutput
        )
    }

    private static func pluginSourceParts(
        _ source: String
    ) -> (remoteURL: String, manifestPath: String)? {
        let parts = source.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2,
              !parts[0].isEmpty,
              !parts[1].isEmpty,
              parts[0] != ".",
              parts[0] != "..",
              parts[1] != ".",
              parts[1] != "..",
              parts[0].allSatisfy(Self.isGitHubSegmentCharacter),
              parts[1].allSatisfy(Self.isGitHubSegmentCharacter) else {
            return nil
        }
        let subdirectory = parts.dropFirst(2)
        guard subdirectory.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".."
                && !$0.contains("\\") && !$0.contains("\0")
        }) else {
            return nil
        }
        let owner = String(parts[0])
        let repository = String(parts[1])
        let manifestPath = (
            subdirectory.map(String.init) + ["herdr-plugin.toml"]
        ).joined(separator: "/")
        return (
            "https://github.com/\(owner)/\(repository).git",
            manifestPath
        )
    }

    private static func isGitHubSegmentCharacter(_ character: Character) -> Bool {
        character.isASCII
            && (character.isLetter
                || character.isNumber
                || character == "-"
                || character == "_"
                || character == ".")
    }

    func pluginLink(path: String) async -> String {
        guard remoteTarget == nil else {
            return "Plugin link is available only for a local Herdr server."
        }
        return await commandOutput(
            ["plugin", "link", path],
            fallback: "Herdr linked the plugin."
        )
    }

    func pluginUninstall(_ pluginID: String) async -> String {
        guard remoteTarget == nil else {
            return "Plugin uninstall is available only for a local Herdr server."
        }
        return await commandOutput(
            ["plugin", "uninstall", pluginID],
            fallback: "Herdr uninstalled the plugin."
        )
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

    func herdrChannel() async -> String {
        guard remoteTarget == nil else {
            return "Update channel control is available only for local Herdr."
        }
        return await commandOutput(
            ["channel", "show"],
            usesActiveSocket: false,
            fallback: "Unable to read the Herdr update channel."
        )
    }

    func setHerdrChannel(
        _ channel: String
    ) async -> (succeeded: Bool, output: String) {
        guard remoteTarget == nil else {
            return (
                false,
                "Update channel control is available only for local Herdr."
            )
        }
        guard channel == "stable" || channel == "preview" else {
            return (
                false,
                "Herdr supports only stable and preview channels."
            )
        }
        let result = await runHerdrResult(
            ["channel", "set", channel],
            usesActiveSocket: false,
        )
        let fallback = result.succeeded
            ? "Herdr now uses the \(channel) channel."
            : "Unable to change the Herdr update channel."
        return (
            result.succeeded,
            result.displayOutput.isEmpty ? fallback : result.displayOutput
        )
    }

    func agentManifestStatus() async -> String {
        return await commandOutput(
            ["server", "agent-manifests"],
            fallback: "Unable to read agent detection manifests."
        )
    }

    func updateAgentManifests() async -> String {
        guard remoteTarget == nil else {
            return "Manifest downloads are available only for local Herdr."
        }
        return await commandOutput(
            ["server", "update-agent-manifests"],
            fallback: "Herdr updated and reloaded agent detection manifests."
        )
    }

    func reloadAgentManifests() async -> String {
        let result = await runHerdrResult(["server", "reload-agent-manifests"])
        guard result.succeeded else {
            return result.errorOutput.isEmpty
                ? "Unable to reload agent detection manifests."
                : result.errorOutput
        }
        return await agentManifestStatus()
    }

    func liveHandoff() async -> String {
        guard remoteTarget == nil else {
            return "Live handoff is available only for a local Herdr server."
        }
        let result = await runHerdrResult(["server", "live-handoff"])
        guard result.succeeded else {
            return result.errorOutput.isEmpty
                ? "Herdr live handoff failed."
                : result.errorOutput
        }
        await reconnectAfterServerReplacement()
        return result.displayOutput.isEmpty
            ? "Herdr handed live panes to a new server."
            : result.displayOutput
    }

    func updateHerdr() async -> String {
        guard remoteTarget == nil else {
            return "Herdr update is available only for a local server."
        }
        let result = await runHerdrResult(
            ["update", "--handoff"]
        )
        if result.succeeded,
           result.displayOutput.localizedCaseInsensitiveContains(
               "live handoff complete"
           ) {
            await reconnectAfterServerReplacement()
        }
        if result.displayOutput.isEmpty {
            return result.succeeded
                ? "Herdr is up to date."
                : "Herdr update failed or returned no output."
        }
        return result.displayOutput
    }

    func herdrNews() -> [HerdrNewsItem] {
        [
            Self.loadReleaseNotes(),
            Self.loadProductAnnouncement(),
        ]
        .compactMap { $0 }
    }

    func stopServer() async -> Bool {
        await runHerdr(["server", "stop"])
    }

    private func commandOutput(
        _ arguments: [String],
        usesActiveSocket: Bool = true,
        fallback: String
    ) async -> String {
        let result = await runHerdrResult(
            arguments,
            usesActiveSocket: usesActiveSocket
        )
        if !result.displayOutput.isEmpty {
            return result.displayOutput
        }
        return result.succeeded ? fallback : "Herdr command failed."
    }

    /// Handoff preserves pane runtimes, but it drops all client sockets.
    /// Rebuild both client types so Rai does not rely on short retry windows.
    private func reconnectAfterServerReplacement() async {
        connectionGeneration = UUID()
        eventTask?.cancel()
        eventTask = nil
        flushTask?.cancel()
        flushTask = nil
        trailingRefreshTask?.cancel()
        trailingRefreshTask = nil
        pendingEvents.removeAll(keepingCapacity: false)
        client.disconnect()
        terminalPool.removeAll()
        lastObservedPaneStatuses = nil
        pluginActionsGeneration = nil

        let generation = UUID()
        connectionGeneration = generation
        client = HerdrClient(socketPath: activeSocketPath)
        connectionState = .connecting
        await refreshSnapshot(
            keepSelection: true,
            client: client,
            generation: generation
        )
        guard generation == connectionGeneration else { return }
        startEventLoop(client: client, generation: generation)
    }

    private static func loadReleaseNotes() -> HerdrNewsItem? {
        let url = herdrConfigDirectory()
            .appendingPathComponent("release-notes.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let object = jsonDictionary(at: url),
              let version = nonemptyString(object["version"]),
              let body = nonemptyString(object["body"]) else {
            return unreadableNewsItem(
                id: "release-notes",
                title: "Release notes unavailable",
                subtitle: url.path
            )
        }
        return HerdrNewsItem(
            id: "release-notes-\(version)",
            title: "Herdr \(version)",
            subtitle: "Release notes",
            body: body
        )
    }

    private static func loadProductAnnouncement() -> HerdrNewsItem? {
        let stateDirectory = herdrStateDirectory()
        let candidates = [
            stateDirectory.appendingPathComponent("product-announcements.json"),
            stateDirectory.appendingPathComponent("product_announcements.json"),
            herdrConfigDirectory().appendingPathComponent(
                "product_announcements.json"
            ),
        ]
        guard let url = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            return nil
        }
        guard let store = jsonDictionary(at: url) else {
            return unreadableNewsItem(
                id: "product-announcement",
                title: "Product announcement unavailable",
                subtitle: url.path
            )
        }
        let announcement: [String: Any]
        if let latest = store["latest"] {
            if latest is NSNull {
                return nil
            }
            guard let latest = latest as? [String: Any] else {
                return unreadableNewsItem(
                    id: "product-announcement",
                    title: "Product announcement unavailable",
                    subtitle: url.path
                )
            }
            announcement = latest
        } else {
            announcement = store
        }
        guard let version = nonemptyString(announcement["version"]),
              let identifier = nonemptyString(announcement["id"]),
              let body = nonemptyString(announcement["body"]) else {
            return unreadableNewsItem(
                id: "product-announcement",
                title: "Product announcement unavailable",
                subtitle: url.path
            )
        }
        let title = nonemptyString(announcement["title"]) ?? "Product announcement"
        return HerdrNewsItem(
            id: "product-announcement-\(version)-\(identifier)",
            title: title,
            subtitle: "Product announcement · Herdr \(version)",
            body: body
        )
    }

    private static func unreadableNewsItem(
        id: String,
        title: String,
        subtitle: String
    ) -> HerdrNewsItem {
        HerdrNewsItem(
            id: id,
            title: title,
            subtitle: subtitle,
            body: "Herdr wrote a file that Rai could not parse."
        )
    }

    private static func jsonDictionary(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return object as? [String: Any]
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func herdrConfigDirectory() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["HERDR_CONFIG_PATH"], !path.isEmpty {
            return URL(fileURLWithPath: path).deletingLastPathComponent()
        }
        if let path = environment["XDG_CONFIG_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path).appendingPathComponent("herdr")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/herdr")
    }

    private static func herdrStateDirectory() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["XDG_STATE_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path).appendingPathComponent("herdr")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/herdr")
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
        let process = configuredHerdrProcess(args)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
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
        } onCancel: {
            // A terminated capture resumes through the exit path above with a
            // non-zero status → nil. Callers that time out (processInfo) rely
            // on this to end the subprocess instead of leaking it.
            if process.isRunning {
                process.terminate()
            }
        }
    }

    private struct HerdrCommandResult {
        let succeeded: Bool
        let standardOutput: String
        let standardError: String

        var displayOutput: String {
            [
                standardError.trimmingCharacters(in: .whitespacesAndNewlines),
                standardOutput.trimmingCharacters(in: .whitespacesAndNewlines),
            ]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        }

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
        await runProcessResult(
            configuredHerdrProcess(
                args,
                usesActiveSocket: usesActiveSocket
            )
        )
    }

    private func runExternalResult(
        _ executablePath: String,
        _ arguments: [String]
    ) async -> HerdrCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        return await runProcessResult(process)
    }

    private func runProcessResult(
        _ process: Process
    ) async -> HerdrCommandResult {
        await withCheckedContinuation { continuation in
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
            let outputCapture = HerdrPipeCapture()
            let errorCapture = HerdrPipeCapture()
            let readers = DispatchGroup()
            readers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                outputCapture.read(from: standardOutput.fileHandleForReading)
                readers.leave()
            }
            readers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                errorCapture.read(from: standardError.fileHandleForReading)
                readers.leave()
            }
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                readers.wait()
                continuation.resume(
                    returning: HerdrCommandResult(
                        succeeded: process.terminationStatus == 0,
                        standardOutput: outputCapture.string(),
                        standardError: errorCapture.string()
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
