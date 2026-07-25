import CorralCore
import Foundation
import SwiftUI

@MainActor
protocol CorralSnapshotObserver: AnyObject {
    func corralModel(
        _ model: CorralModel,
        didRefresh snapshot: SessionSnapshot,
        transitions: [PaneStatusTransition]
    )
}

enum AgentLaunchKind: String {
    case claude
    case codex
}

@MainActor
final class CorralModel: ObservableObject {
    enum ConnectionState: Equatable {
        case connecting
        case connected(version: String, protocolVersion: Int)
        case disconnected(String)
    }

    @Published private(set) var snapshot: SessionSnapshot?
    @Published private(set) var connectionState: ConnectionState = .connecting
    @Published var selectedPaneID: String?
    @Published var draggedPaneID: String?
    @Published var onlyNeedsYou = false
    @Published var notificationsMuted: Bool {
        didSet {
            userDefaults.set(
                notificationsMuted,
                forKey: Self.notificationsMutedDefaultsKey
            )
        }
    }
    @Published var isCommandPalettePresented = false
    @Published var paletteQuery = ""
    @Published var paletteSelectedID: String?
    @Published var renameRequest: RenameRequest?
    @Published var workspacePendingClose: Workspace?
    @Published var statusExplanation: StatusExplanation?
    @Published var worktreeCreateRequest: WorktreeCreateRequest?
    @Published var worktreeOpenRequest: WorktreeOpenRequest?
    @Published var worktreeAlert: WorktreeAlert?
    // Live split ratio while a divider is being dragged (split id → ratio),
    // for smooth local feedback; cleared once herdr's snapshot reflects the commit.
    @Published var dragRatios: [String: Double] = [:]

    let client: HerdrClient
    let terminalPool = TerminalPool()

    weak var snapshotObserver: CorralSnapshotObserver?

    private static let notificationsMutedDefaultsKey = "notificationsMuted"
    private let userDefaults: UserDefaults
    private var started = false
    private var eventTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var pendingEvents: [HerdrEvent] = []
    private var lastObservedPaneStatuses: [String: AgentStatus]?

    init(
        client: HerdrClient = HerdrClient(),
        userDefaults: UserDefaults = .standard
    ) {
        self.client = client
        self.userDefaults = userDefaults
        notificationsMuted = userDefaults.bool(
            forKey: Self.notificationsMutedDefaultsKey
        )
    }

    deinit {
        eventTask?.cancel()
        flushTask?.cancel()
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
        connectionState = .connecting

        Task {
            await refreshSnapshot(keepSelection: false)
            startEventLoop()
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
        Task {
            do {
                try await client.focusPane(paneID)
            } catch {
                connectionState = .disconnected(error.localizedDescription)
            }
        }
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

    func close(tab: HerdrTab) {
        runAction(["tab", "close", tab.tabID])
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

        Task {
            let result = await runHerdrResult(arguments)
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

        Task {
            let result = await runHerdrResult([
                "worktree", "list",
                "--cwd", context.checkoutPath,
                "--json",
            ])
            guard worktreeOpenRequest?.id == request.id else { return }

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

        Task {
            let result = await runHerdrResult([
                "worktree", "open",
                "--cwd", request.context.checkoutPath,
                "--path", worktree.path,
                "--no-focus",
            ])
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
        Task {
            var arguments = [
                "worktree", "remove",
                "--workspace", workspace.workspaceID,
            ]
            if force {
                arguments.append("--force")
            }
            let result = await runHerdrResult(arguments)
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
        Task {
            do {
                try await client.moveTab(sourceTabID, insertIndex: insertIndex)
                await refreshSnapshot(keepSelection: true)
            } catch {
                connectionState = .disconnected(error.localizedDescription)
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
        Task {
            do {
                try await client.moveWorkspace(sourceWorkspaceID, insertIndex: insertIndex)
                await refreshSnapshot(keepSelection: true)
            } catch {
                connectionState = .disconnected(error.localizedDescription)
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
        Task {
            let output = await runHerdrCapture(["agent", "explain", target, "--json"])
            guard statusExplanation?.id == id else { return }
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

    private func startEventLoop() {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let paneIDs = snapshot?.panes.map(\.paneID) ?? []
                    for try await event in client.events(paneIDs: paneIDs) {
                        queue(event)
                    }
                } catch {
                    if !Task.isCancelled {
                        connectionState = .disconnected(error.localizedDescription)
                    }
                }
                guard !Task.isCancelled else { break }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func queue(_ event: HerdrEvent) {
        pendingEvents.append(event)
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !Task.isCancelled else { return }
            await self.flushEvents()
        }
    }

    private func flushEvents() async {
        let events = pendingEvents
        pendingEvents.removeAll(keepingCapacity: true)
        flushTask = nil
        guard !events.isEmpty else { return }

        // The terminal content itself is rendered by each pane's attach process,
        // so we only need to re-snapshot on structural changes (create/close/move/
        // focus/status) — never on raw output.
        let structural = events.contains { $0.name != "pane.output_changed" }
        if structural {
            await refreshSnapshot(keepSelection: true)
        }
    }

    private func refreshSnapshot(keepSelection: Bool) async {
        do {
            let newSnapshot = try await client.snapshot()
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

            let selectionStillValid = selectedPaneID.map { id in
                newSnapshot.panes.contains { $0.paneID == id }
            } ?? false

            if !(keepSelection && selectionStillValid) {
                selectedPaneID = newSnapshot.focusedPaneID
                    ?? newSnapshot.panes.first(where: \.focused)?.paneID
                    ?? newSnapshot.panes.first?.paneID
            }

            snapshotObserver?.corralModel(
                self,
                didRefresh: newSnapshot,
                transitions: transitions
            )
        } catch {
            connectionState = .disconnected(error.localizedDescription)
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

    // Structural changes go through the herdr CLI (the binary corral already
    // spawns for attach), then we adopt herdr's resulting focus.
    func newTab() {
        guard let workspace = selectedWorkspace?.workspaceID else { return }
        runAction(["tab", "create", "--workspace", workspace, "--focus"])
    }
    func closeTab() {
        guard let tab = selectedTabID else { return }
        runAction(["tab", "close", tab])
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

        Task {
            // agent start --split uses herdr's focused pane as the split source.
            // Await focus so a pane-bar action cannot race and split the wrong pane.
            do {
                try await client.focusPane(paneID)
            } catch {
                connectionState = .disconnected(error.localizedDescription)
                return
            }
            _ = await runHerdr(
                PaneActionPlanner.agentStartArguments(
                    name: name,
                    executable: kind.rawValue,
                    direction: direction,
                    cwd: pane.cwd
                )
            )
            await refreshSnapshot(keepSelection: true)
        }
    }

    private static func defaultAgentName(_ kind: AgentLaunchKind) -> String {
        let suffix = UUID().uuidString.prefix(6).lowercased()
        return "\(kind.rawValue)-\(suffix)"
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
        Task {
            _ = await runHerdr(["pane", "resize", "--pane", pane, "--direction", dir, "--amount", amount])
            await refreshSnapshot(keepSelection: true)
            dragRatios.removeValue(forKey: splitID)
        }
    }

    private func runAction(_ args: [String], followFocus: Bool = true) {
        Task {
            _ = await runHerdr(args)
            await refreshSnapshot(keepSelection: !followFocus)
        }
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

    private func runHerdrResult(_ args: [String]) async -> HerdrCommandResult {
        await withCheckedContinuation { continuation in
            let process = configuredHerdrProcess(args)
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

    private func configuredHerdrProcess(_ args: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: HerdrCLI.binaryPath)
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        let path = environment["PATH"] ?? ""
        if !path.contains("/opt/homebrew/bin") {
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:"
                + (path.isEmpty ? "/usr/bin:/bin" : path)
        }
        process.environment = environment
        return process
    }
}
