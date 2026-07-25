import CorralCore
import Foundation
import SwiftUI

struct TerminalFrame: Equatable {
    let paneID: String
    let text: String
    let revision: UInt64
    let sequence: UInt64
}

@MainActor
final class CorralModel: ObservableObject {
    enum ConnectionState: Equatable {
        case connecting
        case connected(version: String, protocolVersion: Int)
        case disconnected(String)
    }

    @Published private(set) var snapshot: SessionSnapshot?
    @Published private(set) var terminalFrames: [String: TerminalFrame] = [:]
    @Published private(set) var connectionState: ConnectionState = .connecting
    @Published var selectedPaneID: String?

    let client: HerdrClient

    private var started = false
    private var eventTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var pendingEvents: [HerdrEvent] = []
    private var frameSequence: UInt64 = 0
    private var readsInFlight = Set<String>()

    init(client: HerdrClient = HerdrClient()) {
        self.client = client
    }

    deinit {
        eventTask?.cancel()
        pollTask?.cancel()
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

    func terminalFrame(for paneID: String) -> TerminalFrame? {
        terminalFrames[paneID]
    }

    func start() {
        guard !started else { return }
        started = true
        connectionState = .connecting

        Task {
            await refreshSnapshot(keepSelection: false)
            startEventLoop()
            startOutputFallback()
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

    func select(paneID: String, focusInHerdr: Bool) {
        let previousTabID = selectedTabID
        let nextTabID = snapshot?.panes.first { $0.paneID == paneID }?.tabID
        let changed = selectedPaneID != paneID
        selectedPaneID = paneID
        Task {
            if focusInHerdr {
                do {
                    try await client.focusPane(paneID)
                } catch {
                    connectionState = .disconnected(error.localizedDescription)
                }
            }
            if changed, previousTabID != nextTabID {
                await refreshVisiblePanes(force: false)
            } else if terminalFrames[paneID] == nil {
                await refreshPane(paneID: paneID, force: true)
            }
        }
    }

    func refreshNow() {
        Task {
            await refreshSnapshot(keepSelection: true)
        }
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

    private func startOutputFallback() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(700))
                guard let self, self.selectedPaneID != nil else { continue }
                await self.refreshVisiblePanes(force: false)
            }
        }
    }

    private func queue(_ event: HerdrEvent) {
        pendingEvents.append(event)
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(90))
            guard let self, !Task.isCancelled else { return }
            await self.flushEvents()
        }
    }

    private func flushEvents() async {
        let events = pendingEvents
        pendingEvents.removeAll(keepingCapacity: true)
        flushTask = nil
        guard !events.isEmpty else { return }

        let visiblePaneIDs = Set(visiblePanes.map(\.paneID))
        let changedOutputPaneIDs = Set(events.compactMap {
            $0.name == "pane.output_changed" ? $0.paneID : nil
        }).intersection(visiblePaneIDs)
        let outputChanged = !changedOutputPaneIDs.isEmpty
        let treeChanged = events.contains {
            $0.name != "pane.output_changed"
        }

        if treeChanged {
            await refreshSnapshot(keepSelection: true)
        } else if outputChanged {
            for paneID in changedOutputPaneIDs {
                await refreshPane(paneID: paneID, force: true)
            }
        }
    }

    private func refreshSnapshot(keepSelection: Bool) async {
        do {
            let newSnapshot = try await client.snapshot()
            snapshot = newSnapshot
            let livePaneIDs = Set(newSnapshot.panes.map(\.paneID))
            terminalFrames = terminalFrames.filter { livePaneIDs.contains($0.key) }
            connectionState = .connected(
                version: newSnapshot.version,
                protocolVersion: newSnapshot.protocol
            )

            if keepSelection,
               let selectedPaneID,
               newSnapshot.panes.contains(where: { $0.paneID == selectedPaneID }) {
                await refreshVisiblePanes(force: false)
            } else {
                selectedPaneID = newSnapshot.focusedPaneID
                    ?? newSnapshot.panes.first(where: \.focused)?.paneID
                    ?? newSnapshot.panes.first?.paneID
                await refreshVisiblePanes(force: true)
            }
        } catch {
            connectionState = .disconnected(error.localizedDescription)
        }
    }

    private func refreshVisiblePanes(force: Bool) async {
        for pane in visiblePanes {
            await refreshPane(paneID: pane.paneID, force: force)
        }
    }

    private func refreshPane(paneID: String, force: Bool) async {
        guard !readsInFlight.contains(paneID) else { return }
        readsInFlight.insert(paneID)
        defer { readsInFlight.remove(paneID) }

        do {
            let read = try await client.readPane(paneID: paneID)
            if !force,
               let frame = terminalFrames[paneID],
               frame.revision == read.revision,
               frame.text == read.text {
                return
            }
            frameSequence &+= 1
            terminalFrames[paneID] = TerminalFrame(
                paneID: paneID,
                text: read.text,
                revision: read.revision,
                sequence: frameSequence
            )
            if case .disconnected = connectionState, let snapshot {
                connectionState = .connected(
                    version: snapshot.version,
                    protocolVersion: snapshot.protocol
                )
            }
        } catch {
            connectionState = .disconnected(error.localizedDescription)
        }
    }
}
