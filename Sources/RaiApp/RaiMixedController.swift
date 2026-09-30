import Combine
import Foundation
import RaiCore

/// Coordinates local Rai composition with the endpoint sessions that render it.
@MainActor
final class RaiMixedController: ObservableObject {
    let primaryModel: RaiModel
    let model: RaiMixedViewModel

    @Published private(set) var sessions: [MachineEndpoint: RaiMixedEndpointSession] = [:]
    @Published var selectedTabID: UUID?
    @Published var sourcePickerPresented = false

    private let machines = MachineDirectory.shared
    private var machineObservation: AnyCancellable?
    private var compositionObservation: AnyCancellable?
    private var started = false
    private var sourcePickerRequested = false

    init(primaryModel: RaiModel, model: RaiMixedViewModel? = nil) {
        self.primaryModel = primaryModel
        self.model = model ?? RaiMixedViewModel()
        compositionObservation = self.model.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        machineObservation = machines.$state.sink { [weak self] _ in
            self?.syncSessions()
        }
    }

    var isMixedSelected: Bool { selectedTabID != nil }

    var spaces: [RaiSpace] { model.composition.spaces }

    var selectedTab: RaiTab? {
        selectedTabID.flatMap { model.composition.tab(id: $0) }
    }

    func start() {
        guard !started else { return }
        started = true
        _ = model.load()
        selectedTabID = selectedTabID ?? model.composition.tabs.first?.id
        Task { [weak self] in
            guard let self else { return }
            await machines.perform(.init(revision: machines.state.revision, operation: .refresh))
            syncSessions()
        }
    }

    func selectTab(_ id: UUID) {
        guard model.composition.tab(id: id) != nil else { return }
        selectedTabID = id
        primaryModel.selectedPaneID = nil
        primaryModel.terminalPool.removeAll()
        syncSessions()
    }

    func selectPrimary() {
        guard selectedTabID != nil else { return }
        selectedTabID = nil
        primaryModel.terminalPool.removeAll()
    }

    func newTab() {
        guard let id = model.newTab(after: selectedTabID) else { return }
        selectedTabID = id
        primaryModel.selectedPaneID = nil
        _ = model.save()
        syncSessions()
    }

    func selectTab(index: Int) {
        let tabs = model.composition.tabs
        guard tabs.indices.contains(index) else { return }
        selectTab(tabs[index].id)
    }

    func cycleTab(by delta: Int) {
        let tabs = model.composition.tabs
        guard !tabs.isEmpty else { return }
        let index = tabs.firstIndex { $0.id == selectedTabID } ?? 0
        let next = (index + delta + tabs.count) % tabs.count
        selectTab(tabs[next].id)
    }

    func openSourcePicker() {
        sourcePickerRequested = true
        sourcePickerPresented = true
        Task { [weak self] in
            guard let self else { return }
            await machines.perform(.init(revision: machines.state.revision, operation: .refresh))
            syncSessions(includeAllEntries: true)
        }
    }

    func addWorkspace(_ workspace: MixedWorkspace, endpoint: MachineEndpoint) {
        guard let session = sessions[endpoint] else { return }
        let space: RaiSpace
        if let existing = model.composition.spaces.first(where: { $0.source == workspace.reference }) {
            space = existing
        } else {
            let newSpace = RaiSpace(label: workspace.label, source: workspace.reference)
            guard model.addSpace(newSpace) else { return }
            space = newSpace
        }

        let tabs = tabs(in: session.snapshot, workspaceID: workspace.workspaceID)
        for (index, tab) in tabs.enumerated() {
            let slots = panes(in: session.snapshot, workspaceID: workspace.workspaceID, tabID: tab.id).map {
                RaiPaneSlot(source: RaiPaneReference(
                    endpoint: endpoint,
                    workspaceID: workspace.workspaceID,
                    tabID: tab.id,
                    paneID: $0.id
                ))
            }
            let raiTab = RaiTab(
                label: tab.label.isEmpty ? "Tab \(index + 1)" : tab.label,
                paneSlots: slots
            )
            if model.addTab(raiTab, to: space.id), selectedTabID == nil {
                selectedTabID = raiTab.id
            }
        }
        _ = model.save()
        sourcePickerPresented = false
        primaryModel.selectedPaneID = nil
        primaryModel.terminalPool.removeAll()
        syncSessions()
    }

    func addPanesToSelectedTab(_ workspace: MixedWorkspace, endpoint: MachineEndpoint) {
        guard let selectedTabID, let session = sessions[endpoint] else { return }
        if !model.composition.spaces.contains(where: { $0.source == workspace.reference }) {
            guard model.addSpace(RaiSpace(label: workspace.label, source: workspace.reference)) else { return }
        }
        for tab in tabs(in: session.snapshot, workspaceID: workspace.workspaceID) {
            for pane in panes(in: session.snapshot, workspaceID: workspace.workspaceID, tabID: tab.id) {
                let slot = RaiPaneSlot(source: RaiPaneReference(
                    endpoint: endpoint,
                    workspaceID: workspace.workspaceID,
                    tabID: tab.id,
                    paneID: pane.id
                ))
                _ = model.addPaneSlot(slot, to: selectedTabID)
            }
        }
        _ = model.save()
    }

    func workspaces(for endpoint: MachineEndpoint) -> [MixedWorkspace] {
        guard let snapshot = sessions[endpoint]?.snapshot else { return [] }
        return snapshot.workspaces.compactMap { value in
            guard let object = value.objectValue,
                  let id = object["workspace_id"]?.stringValue else { return nil }
            let label = object["label"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let identity = "\(endpoint.profileID ?? "local")/\(endpoint.session)/\(id)"
            return MixedWorkspace(
                id: identity,
                workspaceID: id,
                label: label?.isEmpty == false ? label! : id,
                reference: .init(endpoint: endpoint, workspaceID: id)
            )
        }
    }

    private func syncSessions(includeAllEntries: Bool = false) {
        guard started else { return }
        let entries = Dictionary(uniqueKeysWithValues: machines.state.entries.map { ($0.endpoint, $0) })
        let needed = Set(model.composition.spaces.map(\.source.endpoint))
            .union(includeAllEntries || sourcePickerRequested ? Set(entries.keys) : [])

        for endpoint in Array(sessions.keys) where !needed.contains(endpoint) {
            sessions[endpoint]?.stop()
            sessions.removeValue(forKey: endpoint)
            model.disconnect(endpoint: endpoint)
        }

        for entry in machines.state.entries where needed.contains(entry.endpoint) {
            guard let connectionID = entry.connectionID,
                  let socketPath = machines.resolve(entry.endpoint, connectionID: connectionID) else { continue }
            connect(entry, socketPath: socketPath)
        }
    }

    private func connect(_ entry: MachineEntry, socketPath: String) {
        let sharesPrimaryPool = socketPath == primaryModel.activeSocketPath
        if let session = sessions[entry.endpoint],
           session.connectionID == entry.connectionID,
           session.apiSocketPath == socketPath,
           !session.hasError,
           sharesPrimaryPool == (session.pool === primaryModel.terminalPool) {
            return
        }
        sessions[entry.endpoint]?.stop()
        model.disconnect(endpoint: entry.endpoint)
        let session = RaiMixedEndpointSession(
            endpoint: entry.endpoint,
            connectionID: entry.connectionID ?? "",
            socketPath: socketPath,
            sharedTerminalPool: sharesPrimaryPool ? primaryModel.terminalPool : nil,
            projectionModel: model
        )
        sessions[entry.endpoint] = session
        session.start()
    }

    private func tabs(in snapshot: HerdrEndpointSnapshot?, workspaceID: String) -> [MixedTab] {
        snapshot?.tabs.compactMap { value in
            guard let object = value.objectValue,
                  object["workspace_id"]?.stringValue == workspaceID,
                  let id = object["tab_id"]?.stringValue else { return nil }
            return MixedTab(id: id, label: object["label"]?.stringValue ?? "")
        } ?? []
    }

    private func panes(in snapshot: HerdrEndpointSnapshot?, workspaceID: String, tabID: String) -> [MixedPane] {
        snapshot?.panes.compactMap { value in
            guard let object = value.objectValue,
                  object["workspace_id"]?.stringValue == workspaceID,
                  object["tab_id"]?.stringValue == tabID,
                  let id = object["pane_id"]?.stringValue else { return nil }
            return MixedPane(id: id)
        } ?? []
    }
}

struct MixedWorkspace: Identifiable {
    let id: String
    let workspaceID: String
    let label: String
    let reference: RaiWorkspaceReference
}

struct MixedTab {
    let id: String
    let label: String
}

struct MixedPane {
    let id: String
}
