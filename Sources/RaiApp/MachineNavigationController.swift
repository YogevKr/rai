import AppKit
import Combine
import Foundation
import RaiCore

/// One native space model per Herdr instance. Selection never changes ownership.
@MainActor
final class MachineNavigationController: ObservableObject {
    let primaryModel: RaiModel
    @Published private(set) var models: [MachineEndpoint: RaiModel] = [:]
    @Published private(set) var entries: [MachineEntry] = []
    @Published private(set) var selectedEndpoint: MachineEndpoint
    @Published private(set) var collapsedMachines: Set<MachineEndpoint> = []
    private let directory: MachineDirectory
    private let makeModel: (MachineEntry) -> RaiModel
    private let connects: Bool
    private var observations: [MachineEndpoint: AnyCancellable] = [:]
    private var catalogObservation: AnyCancellable?
    private var terminationObservation: AnyCancellable?
    private var refreshTask: Task<Void, Never>?
    private var reconnectAfter: [MachineEndpoint: Date] = [:]
    private var rememberedTabs: [RaiWorkspaceReference: String] = [:]

    init(primaryModel: RaiModel, directory: MachineDirectory? = nil,
         connects: Bool = true, makeModel: ((MachineEntry) -> RaiModel)? = nil) {
        let directory = directory ?? .shared
        self.primaryModel = primaryModel
        self.directory = directory
        self.connects = connects
        self.makeModel = makeModel ?? { RaiModel(machineEntry: $0) }
        selectedEndpoint = primaryModel.currentMachineEntry?.endpoint
            ?? MachineEndpoint(session: primaryModel.currentSessionName)
        reconcile([])
        catalogObservation = directory.$state.dropFirst().sink { [weak self] state in
            Task { @MainActor [weak self] in self?.reconcile(state.entries) }
        }
        terminationObservation = NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.stop() }
    }

    var activeModel: RaiModel { models[selectedEndpoint] ?? primaryModel }

    var machineState: MachineDirectoryState {
        var result = directory.state
        result.entries = result.entries.map { entry in
            guard let model = models[entry.endpoint] else { return entry }
            var entry = entry
            switch model.connectionState {
            case .connected: entry.health = .online; entry.error = nil
            case .connecting: entry.health = .connecting
            case .disconnected(let error): entry.health = .disconnected; entry.error = error
            }
            return entry
        }
        return result
    }

    func perform(_ operation: MachineOperation) {
        if case .reconnect(let endpoint) = operation,
           let model = models[endpoint], model !== primaryModel,
           let entry = entries.first(where: { $0.endpoint == endpoint }) {
            connect(model, entry: entry)
            return
        }
        Task { await directory.perform(.init(revision: directory.state.revision, operation: operation)) }
    }

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await directory.refreshCatalogOnly()
                reconnectDisconnectedMachines()
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        for model in models.values where model !== primaryModel { model.stopMachineConnection() }
    }

    /// Catalog order is stable. The primary local instance always comes first.
    func reconcile(_ catalog: [MachineEntry]) {
        guard let primary = primaryModel.currentMachineEntry else { return }
        var next = [primary]
        next += catalog.filter { entry in
            entry.health != .disabled && entry.endpoint != primary.endpoint
                && !(entry.target != nil && entry.target == primary.target
                     && entry.endpoint.session == primary.endpoint.session)
        }
        let retained = Set(next.map(\.endpoint))
        for endpoint in Array(models.keys) where !retained.contains(endpoint) {
            if models[endpoint] !== primaryModel { models[endpoint]?.stopMachineConnection() }
            models.removeValue(forKey: endpoint)
            observations.removeValue(forKey: endpoint)
        }
        for entry in next {
            if let model = models[entry.endpoint], model !== primaryModel,
               model.currentMachineEntry?.target != entry.target {
                model.stopMachineConnection()
                models.removeValue(forKey: entry.endpoint)
            }
            if models[entry.endpoint] == nil {
                let model = entry.endpoint == primary.endpoint ? primaryModel : makeModel(entry)
                models[entry.endpoint] = model
                observations[entry.endpoint] = model.objectWillChange.sink { [weak self] _ in
                    self?.objectWillChange.send()
                }
                if connects, model !== primaryModel { connect(model, entry: entry) }
            }
            models[entry.endpoint]?.updateMachineEntry(entry)
        }
        if entries != next { entries = next }
        if !retained.contains(selectedEndpoint) { selectedEndpoint = primary.endpoint }
    }

    func selectMachine(_ endpoint: MachineEndpoint) {
        guard models[endpoint] != nil else { return }
        rememberSelection()
        selectedEndpoint = endpoint
    }

    func selectSpace(_ source: RaiWorkspaceReference) {
        guard let model = models[source.endpoint],
              let workspace = model.snapshot?.workspaces.first(where: { $0.workspaceID == source.workspaceID }) else { return }
        selectMachine(source.endpoint)
        if let tabID = rememberedTabs[source],
           let tab = model.snapshot?.tabs.first(where: { $0.workspaceID == source.workspaceID && $0.tabID == tabID }) {
            model.select(tab: tab)
        } else { model.select(workspace: workspace) }
    }

    func cycleSpace(by delta: Int) {
        let spaces = entries.flatMap { entry -> [RaiWorkspaceReference] in
            guard let model = models[entry.endpoint], model.isConnected else { return [] }
            // Include collapsed spaces, as Herdr does.
            guard let snapshot = model.snapshot else { return [] }
            return WorkspaceSidebar.entries(in: snapshot, gitStatuses: model.workspaceGitStatuses,
                collapsedSpaceKeys: [], visibleWorkspaceID: nil).map {
                RaiWorkspaceReference(endpoint: entry.endpoint, workspaceID: $0.workspace.workspaceID)
            }
        }
        guard !spaces.isEmpty else { return }
        let current = activeModel.selectedWorkspace.map {
            RaiWorkspaceReference(endpoint: selectedEndpoint, workspaceID: $0.workspaceID)
        }
        let index = current.flatMap { spaces.firstIndex(of: $0) }
        let next = index.map { ($0 + delta % spaces.count + spaces.count) % spaces.count }
            ?? (delta < 0 ? spaces.count - 1 : 0)
        collapsedMachines.remove(spaces[next].endpoint)
        selectSpace(spaces[next])
    }

    func newSpace(on endpoint: MachineEndpoint? = nil) {
        let endpoint = endpoint ?? selectedEndpoint
        guard let model = models[endpoint], model.isConnected else { return }
        selectMachine(endpoint)
        collapsedMachines.remove(endpoint)
        model.newWorkspace()
    }

    func toggleCollapsed(_ endpoint: MachineEndpoint) {
        if !collapsedMachines.insert(endpoint).inserted { collapsedMachines.remove(endpoint) }
    }

    private func rememberSelection() {
        guard let workspace = activeModel.selectedWorkspace, let tabID = activeModel.selectedTabID else { return }
        rememberedTabs[.init(endpoint: selectedEndpoint, workspaceID: workspace.workspaceID)] = tabID
    }

    private func reconnectDisconnectedMachines() {
        for entry in entries {
            guard let model = models[entry.endpoint], model !== primaryModel,
                  case .disconnected = model.connectionState,
                  (reconnectAfter[entry.endpoint] ?? .distantPast) <= Date() else { continue }
            connect(model, entry: entry)
        }
    }

    private func connect(_ model: RaiModel, entry: MachineEntry) {
        reconnectAfter[entry.endpoint] = Date().addingTimeInterval(10)
        if let target = entry.target { model.connectRemote(target: target, sessionName: entry.endpoint.session) }
        else if let path = directory.localSocketPath(for: entry.endpoint) { model.connect(toSocket: path) }
    }
}
