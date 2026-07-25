import CorralCore
import Foundation
import SwiftUI

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
    // Live split ratio while a divider is being dragged (split id → ratio),
    // for smooth local feedback; cleared once herdr's snapshot reflects the commit.
    @Published var dragRatios: [String: Double] = [:]

    let client: HerdrClient

    private var started = false
    private var eventTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var pendingEvents: [HerdrEvent] = []

    init(client: HerdrClient = HerdrClient()) {
        self.client = client
    }

    deinit {
        eventTask?.cancel()
        flushTask?.cancel()
    }

    var selectedPane: Pane? {
        snapshot?.panes.first { $0.paneID == selectedPaneID }
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
            .sorted { $0.number < $1.number } ?? []
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
            snapshot = newSnapshot
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
        let spaces = snapshot.workspaces.sorted { $0.number < $1.number }
        guard !spaces.isEmpty else { return }
        let index = spaces.firstIndex { $0.workspaceID == selectedWorkspace?.workspaceID } ?? 0
        let target = spaces[(index + delta + spaces.count) % spaces.count]
        let tabs = snapshot.tabs
            .filter { $0.workspaceID == target.workspaceID }
            .sorted { $0.number < $1.number }
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
            let process = Process()
            process.executableURL = URL(fileURLWithPath: HerdrCLI.binaryPath)
            process.arguments = args
            var env = ProcessInfo.processInfo.environment
            let path = env["PATH"] ?? ""
            if !path.contains("/opt/homebrew/bin") {
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:"
                    + (path.isEmpty ? "/usr/bin:/bin" : path)
            }
            process.environment = env
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus == 0)
            }
            do { try process.run() } catch { continuation.resume(returning: false) }
        }
    }
}
