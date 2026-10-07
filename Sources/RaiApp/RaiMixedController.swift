import Combine
import Foundation
import RaiCore

/// Coordinates local Rai composition with the endpoint sessions that render it.
@MainActor
final class RaiMixedController: ObservableObject {
    let primaryModel: RaiModel
    let model: RaiMixedViewModel

    @Published private(set) var sessions: [MachineEndpoint: RaiMixedEndpointSession] = [:]
    @Published private(set) var remoteWorkspaces: [InstanceWorkspace] = []
    @Published var selectedTabID: UUID?

    @Published private(set) var selectedSourceWorkspace: RaiWorkspaceReference?
    @Published private(set) var selectedSourceTabID: String?
    private let machines: MachineDirectory
    private let closeSource: (InstanceCloseRequest) async throws -> Void
    @Published private(set) var closingWorkspaces: Set<RaiWorkspaceReference> = []
    /// A successful close can reach Herdr before its endpoint stream publishes
    /// the next snapshot. Hide that tab until the stream catches up.
    private var closedSourceTabs: Set<RaiDismissedTab> = []
    private var pendingSourceTabID: String?
    private var snapshotObservation: AnyCancellable?
    private var workspaceObservation: AnyCancellable?
    private var machineObservation: AnyCancellable?
    private var compositionObservation: AnyCancellable?
    private var pendingConnections: Set<MachineEndpoint> = []
    private var started = false

    init(primaryModel: RaiModel, model: RaiMixedViewModel? = nil, machines: MachineDirectory? = nil,
         closeSource: ((InstanceCloseRequest) async throws -> Void)? = nil) {
        let directory = machines ?? .shared
        self.machines = directory
        self.closeSource = closeSource ?? { try await directory.close($0) }
        self.primaryModel = primaryModel
        self.model = model ?? RaiMixedViewModel()
        compositionObservation = self.model.$composition.sink { [weak self] composition in
            guard let self else { return }
            self.updateRemoteWorkspaces(self.machines.workspaces, composition: composition)
        }
        machineObservation = self.machines.$state.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.syncSessions() }
        }
        snapshotObservation = self.machines.$snapshots.sink { [weak self] _ in
            guard self?.selectedSourceWorkspace != nil else { return }
            Task { @MainActor [weak self] in self?.refreshSourceSelection() }
        }
        workspaceObservation = self.machines.$workspaces.sink { [weak self] workspaces in
            guard let self else { return }
            self.updateRemoteWorkspaces(workspaces, composition: self.model.composition)
            Task { @MainActor [weak self] in self?.refreshSourceSelection() }
        }
    }

    var isMixedSelected: Bool { selectedTabID != nil }

    func start() {
        guard !started else { return }
        started = true
        _ = model.load()
        syncSessions()
    }

    func selectTab(_ id: UUID) {
        guard model.composition.tab(id: id) != nil else { return }
        selectedTabID = id
        syncSessions()
    }

    func selectPrimary() {
        guard isMixedSelected || selectedSourceWorkspace != nil else { return }
        selectedSourceWorkspace = nil
        selectedSourceTabID = nil
        pendingSourceTabID = nil
        selectedTabID = nil
        syncSessions()
    }

    func openRemoteWorkspace(
        endpoint: MachineEndpoint,
        workspaceID: String,
        tabID: String? = nil,
        waitForTab: Bool = false
    ) {
        let reference = RaiWorkspaceReference(endpoint: endpoint, workspaceID: workspaceID)
        if !waitForTab || selectedSourceWorkspace != reference {
            pendingSourceTabID = nil
        }
        selectedSourceWorkspace = reference
        selectedSourceTabID = tabID
        refreshSourceSelection()
        syncSessions()
    }

    private var sourceWorkspace: InstanceWorkspace? {
        remoteWorkspaces.first { $0.id == selectedSourceWorkspace }
    }

    private func updateRemoteWorkspaces(_ workspaces: [InstanceWorkspace], composition: RaiComposition) {
        let liveTabs = Set(workspaces.flatMap { workspace in
            workspace.tabs.map { tab in
                RaiDismissedTab(workspace: workspace.id, bootID: workspace.bootID, tabID: tab.id)
            }
        })
        closedSourceTabs = closedSourceTabs.intersection(liveTabs)
        let dismissed = composition.dismissedTabs + Array(closedSourceTabs)
        let visible = workspaces.compactMap { $0.excludingDismissedTabs(dismissed) }
        if remoteWorkspaces != visible { remoteWorkspaces = visible }
    }

    private func refreshSourceSelection() {
        guard selectedSourceWorkspace != nil else { return }
        guard let workspace = sourceWorkspace else {
            if let source = selectedSourceWorkspace,
               machines.state.entry(for: source.endpoint)?.health == .online {
                selectPrimary()
            }
            return
        }
        let tab: InstanceTab?
        if let selectedSourceTabID,
           let selected = workspace.tabs.first(where: { $0.id == selectedSourceTabID }) {
            pendingSourceTabID = nil
            tab = selected
        } else if pendingSourceTabID == selectedSourceTabID {
            return
        } else {
            tab = workspace.tabs.first { $0.id == workspace.activeTabID }
                ?? workspace.tabs.first
        }
        guard let tab else {
            selectPrimary()
            return
        }
        selectedSourceTabID = tab.id
        guard let mixedTabID = model.showSourceTab(tab, spaceLabel: workspace.label) else {
            primaryModel.sessionAlert = SessionAlert(kind: .error(
                title: "Cannot Show Space",
                message: "This space has more panes than Rai can display."
            ))
            selectPrimary()
            return
        }
        selectedTabID = mixedTabID
        syncSessions()
    }

    func newTab() {
        if let source = selectedSourceWorkspace {
            guard let connectionID = machines.state.entry(for: source.endpoint)?.connectionID else { return }
            Task {
                do {
                    let tabID = try await machines.createTab(in: source, connectionID: connectionID)
                    guard selectedSourceWorkspace == source else { return }
                    pendingSourceTabID = tabID
                    openRemoteWorkspace(
                        endpoint: source.endpoint,
                        workspaceID: source.workspaceID,
                        tabID: tabID,
                        waitForTab: true
                    )
                } catch {
                    primaryModel.sessionAlert = SessionAlert(kind: .error(
                        title: "Couldn’t Create Tab", message: error.localizedDescription))
                }
            }
            return
        }
        guard let id = model.newTab(after: selectedTabID) else { return }
        selectedTabID = id
        primaryModel.selectedPaneID = nil
        _ = model.save()
        syncSessions()
    }

    var canCloseSelectedTab: Bool {
        guard let workspace = sourceWorkspace, let tabID = selectedSourceTabID else { return false }
        return !closingWorkspaces.contains(workspace.id) && workspace.tabs.contains { $0.id == tabID }
    }

    func closeSelectedTab() {
        guard canCloseSelectedTab, let workspace = sourceWorkspace, let tabID = selectedSourceTabID else { return }
        closeSourceTab(in: workspace, tabID: tabID)
    }

    /// Close exactly the selected source tab. Hidden siblings can still exist
    /// when the sidebar shows only one tab, so never infer workspace closure.
    @discardableResult
    func closeSourceTab(in workspace: InstanceWorkspace, tabID: String) -> Task<Void, Never>? {
        guard !closingWorkspaces.contains(workspace.id) else { return nil }
        let request: InstanceCloseRequest
        do {
            // A reconnect can replace the displayed connection between the
            // context-menu click and this task. Capture the newest identity.
            let current = remoteWorkspaces.first {
                $0.id == workspace.id && $0.tabs.contains { $0.id == tabID }
            } ?? workspace
            request = try InstanceCloseRequest(workspace: current, tabID: tabID)
        } catch {
            primaryModel.sessionAlert = SessionAlert(kind: .error(
                title: "Couldn’t Close Tab", message: error.localizedDescription))
            return nil
        }
        closingWorkspaces.insert(workspace.id)
        return Task {
            defer { closingWorkspaces.remove(workspace.id) }
            do {
                try await closeSource(request)
                closedSourceTabs.insert(RaiDismissedTab(
                    workspace: request.workspace.id,
                    bootID: request.workspace.bootID,
                    tabID: tabID
                ))
                updateRemoteWorkspaces(machines.workspaces, composition: model.composition)
                if selectedSourceWorkspace == request.workspace.id,
                   selectedSourceTabID == tabID {
                    refreshSourceSelection()
                }
            } catch {
                primaryModel.sessionAlert = SessionAlert(kind: .error(
                    title: "Couldn’t Close Tab", message: error.localizedDescription))
            }
        }
    }

    func removeFromRai(_ workspace: InstanceWorkspace, tabID: String?) {
        guard model.removeSourceTabs(from: workspace, tabID: tabID) else {
            if let error = model.error {
                primaryModel.sessionAlert = SessionAlert(kind: .error(title: "Couldn’t Close Tab", message: error))
            }
            return
        }
        if selectedSourceWorkspace == workspace.id, tabID == nil || selectedSourceTabID == tabID {
            selectPrimary()
        }
        syncSessions()
    }

    func selectTab(index: Int) {
        if let workspace = sourceWorkspace {
            guard workspace.tabs.indices.contains(index) else { return }
            openRemoteWorkspace(endpoint: workspace.id.endpoint, workspaceID: workspace.id.workspaceID,
                                tabID: workspace.tabs[index].id)
            return
        }
        let tabs = model.composition.tabs
        guard tabs.indices.contains(index) else { return }
        selectTab(tabs[index].id)
    }

    func cycleTab(by delta: Int) {
        if let workspace = sourceWorkspace {
            guard !workspace.tabs.isEmpty else { return }
            let index = workspace.tabs.firstIndex { $0.id == selectedSourceTabID } ?? 0
            selectTab(index: (index + delta + workspace.tabs.count) % workspace.tabs.count)
            return
        }
        let tabs = model.composition.tabs
        guard !tabs.isEmpty else { return }
        let index = tabs.firstIndex { $0.id == selectedTabID } ?? 0
        let next = (index + delta + tabs.count) % tabs.count
        selectTab(tabs[next].id)
    }

    private func syncSessions() {
        guard started else { return }
        let needed = selectedSourceWorkspace == nil
            ? Set<MachineEndpoint>()
            : Set(model.composition.spaces.map(\.source.endpoint))

        for endpoint in Array(sessions.keys) {
            guard needed.contains(endpoint),
                  let entry = machines.state.entry(for: endpoint),
                  let connectionID = entry.connectionID,
                  machines.resolve(endpoint, connectionID: connectionID) != nil else {
                sessions[endpoint]?.stop()
                sessions.removeValue(forKey: endpoint)
                model.disconnect(endpoint: endpoint)
                continue
            }
        }

        for entry in machines.state.entries where needed.contains(entry.endpoint) {
            guard let connectionID = entry.connectionID,
                  let socketPath = machines.resolve(entry.endpoint, connectionID: connectionID) else {
                if entry.health == .disconnected,
                   pendingConnections.insert(entry.endpoint).inserted {
                    let endpoint = entry.endpoint
                    Task { [weak self] in
                        guard let self else { return }
                        defer { pendingConnections.remove(endpoint) }
                        _ = try? await machines.ensureConnected(endpoint)
                        syncSessions()
                    }
                }
                sessions.removeValue(forKey: entry.endpoint)?.stop()
                model.disconnect(endpoint: entry.endpoint)
                continue
            }
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
            target: entry.target,
            sharedTerminalPool: sharesPrimaryPool ? primaryModel.terminalPool : nil,
            projectionModel: model
        )
        sessions[entry.endpoint] = session
        session.start()
    }

}
