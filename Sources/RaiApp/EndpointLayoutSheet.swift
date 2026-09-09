import RaiCore
import SwiftUI

struct EndpointLayoutSheet: View {
    let snapshot: HerdrEndpointSnapshot
    let owningViewID: UUID
    let currentViewID: UUID?
    let currentBootID: String?
    let result: EndpointLayoutResult?
    let busy: Bool
    let methods: Set<String>
    let submit: (EndpointLayoutRequest) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var destinationPane = ""
    @State private var destinationWorkspace = ""
    @State private var split = SplitDirection.right
    @State private var beforeTab = ""
    @State private var beforeWorkspace = ""
    @State private var closePreview: WorkspaceClosePreview?
    @State private var pendingID: UUID?
    @State private var status: String?

    private var unavailable: Bool { busy || currentViewID != owningViewID || currentBootID != snapshot.bootID }
    private var workspace: String? { snapshot.focusedWorkspaceID }
    private var pane: String? { snapshot.focusedPaneID }
    private var tab: String? { snapshot.focusedTabID }

    var body: some View {
        NavigationStack {
            Form {
                Section("Target") {
                    Text("Workspace: \(label(workspace, in: snapshot.workspaces, key: "workspace_id"))")
                    Text("Tab: \(label(tab, in: snapshot.tabs, key: "tab_id"))")
                    Text("Pane: \(label(pane, in: snapshot.panes, key: "pane_id"))")
                    Text("These actions use the targets shown here. Reopen this sheet after moving or closing targets.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let pane { resizeSection(pane); moveSection(pane) }
                if let workspace { orderSection(workspace); closeSection(workspace) }
                if let status { Section("Result") { Text(status).textSelection(.enabled) } }
            }
            .formStyle(.grouped)
            .navigationTitle("Layout")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(width: 600, height: 760)
        #endif
        .onAppear { destinationWorkspace = workspace ?? "" }
        .onChange(of: result) { _, value in
            guard let value, value.requestID == pendingID else { return }
            status = value.message; pendingID = nil
        }
        .confirmationDialog(closePreview?.title ?? "Close Workspace?", isPresented: Binding(
            get: { closePreview != nil }, set: { if !$0 { closePreview = nil } }), titleVisibility: .visible) {
                if let preview = closePreview {
                    Button(preview.closeGroup ? "Close Group" : "Close Workspace", role: .destructive) {
                        send(.closeWorkspace(preview)); closePreview = nil
                    }.disabled(unavailable)
                }
            } message: { Text(closePreview?.message ?? "") }
    }

    private func resizeSection(_ pane: String) -> some View {
        Section("Resize Split") {
            ForEach([EndpointBridgeCommand.Direction.left, .right, .up, .down], id: \.rawValue) { direction in
                Button("Resize \(direction.rawValue.capitalized)") { send(.resize(paneID: pane, direction: direction)) }
                    .disabled(unavailable || !methods.contains("pane.resize"))
            }
        }
    }

    private func moveSection(_ pane: String) -> some View {
        Section("Move Pane") {
            Picker("Destination Pane", selection: $destinationPane) {
                Text("Select Pane").tag("")
                ForEach(snapshot.panes.indices, id: \.self) { index in
                    let item = snapshot.panes[index].objectValue ?? [:]
                    if item["tab_id"]?.stringValue != tab, let id = item["pane_id"]?.stringValue {
                        Text("\(item["label"]?.stringValue ?? "Pane") · \(id)").tag(id)
                    }
                }
            }
            Picker("Split Direction", selection: $split) {
                Text("Right").tag(SplitDirection.right); Text("Down").tag(SplitDirection.down)
            }
            Button("Move Beside Pane") {
                guard let item = snapshot.panes.first(where: { $0.objectValue?["pane_id"]?.stringValue == destinationPane }),
                      let tabID = item.objectValue?["tab_id"]?.stringValue else { return }
                send(.movePane(paneID: pane, destination: .tab(tabID: tabID, split: split, targetPaneID: destinationPane)))
            }.disabled(unavailable || destinationPane.isEmpty)
            Picker("Destination Workspace", selection: $destinationWorkspace) {
                choices(snapshot.workspaces, key: "workspace_id", excluding: nil)
            }
            Button("Move to New Tab") {
                send(.movePane(paneID: pane, destination: .newTab(workspaceID: destinationWorkspace, label: nil)))
            }.disabled(unavailable || destinationWorkspace.isEmpty)
            Button("Move to New Workspace") {
                send(.movePane(paneID: pane, destination: .newWorkspace(label: nil, tabLabel: nil)))
            }.disabled(unavailable)
            Text("Moving the last pane can close its old tab or workspace. This view follows the moved pane.")
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(busy)
    }

    private func orderSection(_ workspace: String) -> some View {
        Section("Order") {
            if let tab {
                Picker("Place Tab Before", selection: $beforeTab) {
                    Text("End").tag("")
                    choices(snapshot.tabs.filter { $0.objectValue?["workspace_id"]?.stringValue == workspace }, key: "tab_id", excluding: tab)
                }
                Button("Move Tab") { send(.moveTab(tabID: tab, beforeTabID: beforeTab.isEmpty ? nil : beforeTab)) }
                    .disabled(unavailable || !methods.contains("tab.move"))
            }
            Picker("Place Workspace Before", selection: $beforeWorkspace) {
                Text("End").tag("")
                choices(snapshot.workspaces, key: "workspace_id", excluding: workspace)
            }
            Button("Move Workspace") {
                send(.moveWorkspace(workspaceID: workspace, beforeWorkspaceID: beforeWorkspace.isEmpty ? nil : beforeWorkspace))
            }.disabled(unavailable || !methods.contains("workspace.move"))
        }.disabled(busy)
    }

    private func closeSection(_ workspace: String) -> some View {
        Section("Close") {
            Button("Close Workspace…", role: .destructive) { reviewClose(workspace, group: false) }
            Button("Close Workspace Group…", role: .destructive) { reviewClose(workspace, group: true) }
            Text("Review the workspace names before closing. Closing stops their running processes.")
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(unavailable || !methods.contains("workspace.close"))
    }

    @ViewBuilder
    private func choices(_ items: [JSONValue], key: String, excluding: String?) -> some View {
        ForEach(items.indices, id: \.self) { index in
            let item = items[index].objectValue ?? [:]
            if let id = item[key]?.stringValue, id != excluding { Text("\(item["label"]?.stringValue ?? id) · \(id)").tag(id) }
        }
    }

    private func label(_ id: String?, in items: [JSONValue], key: String) -> String {
        guard let id else { return "None" }
        let name = items.first { $0.objectValue?[key]?.stringValue == id }?.objectValue?["label"]?.stringValue ?? id
        return "\(name) · \(id)"
    }

    private func reviewClose(_ workspace: String, group: Bool) {
        do {
            guard let preview = WorkspaceClosePreview(workspaces: try EndpointLayoutRequest.workspaces(snapshot),
                workspaceID: workspace, closeGroup: group, connectionID: snapshot.bootID) else { throw HerdrEndpointError.staleIdentity }
            _ = try EndpointLayoutRequest(snapshot: snapshot, owningViewID: owningViewID, action: .closeWorkspace(preview))
            closePreview = preview
        } catch { status = error.localizedDescription }
    }

    private func send(_ action: EndpointLayoutAction) {
        guard !unavailable else { return }
        do {
            let request = try EndpointLayoutRequest(snapshot: snapshot, owningViewID: owningViewID, action: action)
            guard submit(request) else { throw HerdrEndpointError.staleIdentity }
            pendingID = request.id; status = "Waiting for the server…"
        } catch { status = "The action did not start. " + error.localizedDescription }
    }
}
