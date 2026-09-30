import RaiCore
import SwiftUI

/// Basic editor for the first mixed view slice.
/// It keeps the existing Rai window and default Herdr session unchanged.
struct RaiMixedWorkspaceView: View {
    @ObservedObject var primaryModel: RaiModel
    @StateObject private var model = RaiMixedViewModel()
    @ObservedObject private var machines = MachineDirectory.shared
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [MachineEndpoint: RaiMixedEndpointSession] = [:]
    @State private var selectedTabID: UUID?

    var body: some View {
        NavigationSplitView {
            List {
                sourceSection
                viewSection
            }
            .navigationTitle("Rai View")
        } detail: {
            if let selectedTabID {
                RaiMixedTabView(model: model, tabID: selectedTabID, endpoints: sessions)
            } else {
                ContentUnavailableView(
                    "Choose a Herdr workspace",
                    systemImage: "rectangle.3.group",
                    description: Text("Add a workspace to create a Rai tab.")
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItem {
                Button {
                    newTab()
                } label: {
                    Label("New Tab", systemImage: "plus")
                }
                .disabled(model.composition.spaces.isEmpty)
            }
            ToolbarItem {
                Button("Save") { _ = model.save() }
                    .disabled(model.composition.spaces.isEmpty)
            }
        }
        .task {
            // The primary view is hidden while this sheet is open. Reap its
            // hosts before the shared pool attaches them to the mixed grid.
            primaryModel.terminalPool.removeAll()
            _ = model.load()
            await machines.perform(.init(revision: machines.state.revision, operation: .refresh))
            selectedTabID = selectedTabID ?? model.composition.tabs.first?.id
            syncSessions()
        }
        .onChange(of: machines.state) { _, _ in syncSessions() }
        .onChange(of: primaryModel.activeSocketPath) { _, _ in
            for session in sessions.values { session.stop() }
            sessions.removeAll()
            syncSessions()
        }
        .onDisappear {
            for session in sessions.values { session.stop() }
            sessions.removeAll()
        }
        .onChange(of: model.composition) { _, value in
            selectedTabID = selectedTabID.flatMap { value.tab(id: $0)?.id }
                ?? value.tabs.first?.id
        }
    }

    private var sourceSection: some View {
        Section("Herdr workspaces") {
            ForEach(machines.state.entries) { entry in
                let session = sessions[entry.endpoint]
                if let snapshot = session?.snapshot {
                    ForEach(workspaces(in: snapshot, endpoint: entry.endpoint), id: \.id) { workspace in
                        HStack {
                            Button {
                                addWorkspace(workspace, endpoint: entry.endpoint)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(workspace.label)
                                        Text(entry.addressLabel)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if model.composition.spaces.contains(where: { $0.source == workspace.reference }) {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(model.composition.spaces.contains(where: { $0.source == workspace.reference }))
                            if selectedTabID != nil {
                                Button {
                                    addPanesToSelectedTab(workspace, endpoint: entry.endpoint)
                                } label: {
                                    Image(systemName: "rectangle.stack.badge.plus")
                                }
                                .buttonStyle(.borderless)
                                .help("Add panes to the selected Rai tab")
                            }
                        }
                    }
                } else {
                    Button {
                        connect(entry)
                    } label: {
                        Label(entry.label, systemImage: entry.health == .online ? "arrow.clockwise" : "link")
                    }
                    .disabled(entry.connectionID == nil || machines.resolve(entry.endpoint, connectionID: entry.connectionID ?? "") == nil)
                }
            }
        }
    }

    private var viewSection: some View {
        Section("Rai tabs") {
            ForEach(model.composition.spaces) { space in
                Section(space.label) {
                    ForEach(space.tabs) { tab in
                        Button {
                            selectedTabID = tab.id
                        } label: {
                            HStack {
                                Text(tab.label.isEmpty ? "Tab" : tab.label)
                                Spacer()
                                Text("\(tab.paneSlots.count)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .listRowBackground(selectedTabID == tab.id ? Color.accentColor.opacity(0.16) : nil)
                    }
                }
            }
        }
    }

    private func newTab() {
        guard let space = model.composition.spaces.first else { return }
        let number = space.tabs.count + 1
        let tab = RaiTab(label: "Rai Tab \(number)")
        guard model.addTab(tab, to: space.id) else { return }
        selectedTabID = tab.id
        _ = model.save()
    }

    private func syncSessions() {
        let entries = Dictionary(uniqueKeysWithValues: machines.state.entries.map { ($0.endpoint, $0) })
        for endpoint in Array(sessions.keys) {
            let current = entries[endpoint]
            let available = current.flatMap { entry in
                entry.connectionID.flatMap { machines.resolve(entry.endpoint, connectionID: $0) }
            } != nil
            guard current != nil, available else {
                sessions[endpoint]?.stop()
                sessions.removeValue(forKey: endpoint)
                model.disconnect(endpoint: endpoint)
                continue
            }
        }
        for entry in machines.state.entries where model.composition.spaces.contains(where: { $0.source.endpoint == entry.endpoint }) {
            connect(entry)
        }
    }

    private func connect(_ entry: MachineEntry) {
        guard let connectionID = entry.connectionID,
              let socketPath = machines.resolve(entry.endpoint, connectionID: connectionID) else { return }
        let sharesPrimaryPool = socketPath == primaryModel.activeSocketPath
        if let session = sessions[entry.endpoint],
           session.connectionID == connectionID,
           session.apiSocketPath == socketPath,
           !session.hasError,
           (sharesPrimaryPool == (session.pool === primaryModel.terminalPool)) { return }
        sessions[entry.endpoint]?.stop()
        model.disconnect(endpoint: entry.endpoint)
        let session = RaiMixedEndpointSession(
            endpoint: entry.endpoint,
            connectionID: connectionID,
            socketPath: socketPath,
            sharedTerminalPool: sharesPrimaryPool ? primaryModel.terminalPool : nil,
            projectionModel: model
        )
        sessions[entry.endpoint] = session
        session.start()
    }

    private func addWorkspace(_ workspace: MixedWorkspace, endpoint: MachineEndpoint) {
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
                    endpoint: endpoint, workspaceID: workspace.workspaceID, tabID: tab.id, paneID: $0.id
                ))
            }
            let raiTab = RaiTab(label: tab.label.isEmpty ? "Tab \(index + 1)" : tab.label, paneSlots: slots)
            if model.addTab(raiTab, to: space.id), selectedTabID == nil { selectedTabID = raiTab.id }
        }
        _ = model.save()
    }

    private func addPanesToSelectedTab(_ workspace: MixedWorkspace, endpoint: MachineEndpoint) {
        guard let selectedTabID, let session = sessions[endpoint] else { return }
        if !model.composition.spaces.contains(where: { $0.source == workspace.reference }) {
            guard model.addSpace(RaiSpace(label: workspace.label, source: workspace.reference)) else { return }
        }
        for tab in tabs(in: session.snapshot, workspaceID: workspace.workspaceID) {
            for pane in panes(in: session.snapshot, workspaceID: workspace.workspaceID, tabID: tab.id) {
                let slot = RaiPaneSlot(source: RaiPaneReference(
                    endpoint: endpoint, workspaceID: workspace.workspaceID, tabID: tab.id, paneID: pane.id
                ))
                _ = model.addPaneSlot(slot, to: selectedTabID)
            }
        }
        _ = model.save()
    }

    private func workspaces(in snapshot: HerdrEndpointSnapshot, endpoint: MachineEndpoint) -> [MixedWorkspace] {
        snapshot.workspaces.compactMap { value in
            guard let object = value.objectValue,
                  let id = object["workspace_id"]?.stringValue else { return nil }
            let label = object["label"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let identity = "\(endpoint.profileID ?? "local")/\(endpoint.session)/\(id)"
            return MixedWorkspace(id: identity, workspaceID: id,
                                  label: label?.isEmpty == false ? label! : id,
                                  reference: .init(endpoint: endpoint, workspaceID: id))
        }
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

private struct MixedWorkspace: Identifiable {
    let id: String
    let workspaceID: String
    let label: String
    let reference: RaiWorkspaceReference
}

private struct MixedTab {
    let id: String
    let label: String
}

private struct MixedPane {
    let id: String
}
