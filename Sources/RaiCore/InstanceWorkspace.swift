import Foundation

/// A live Herdr space in the regular sidebar, identified by its owning instance.
public struct InstanceWorkspace: Identifiable, Equatable, Sendable {
    public let id: RaiWorkspaceReference
    public let label: String
    public let instanceLabel: String
    public let connectionID: String?
    public let bootID: String
    public let activeTabID: String?
    public let tabs: [InstanceTab]

    public static func entries(
        machines: [MachineEntry],
        snapshots: [MachineEndpoint: HerdrEndpointSnapshot],
        excluding primary: MachineEndpoint?
    ) -> [InstanceWorkspace] {
        machines.filter { $0.endpoint != primary && $0.health != .disabled }.flatMap { machine in
            guard let snapshot = snapshots[machine.endpoint] else { return [InstanceWorkspace]() }
            return snapshot.workspaces.compactMap { value in
                guard let object = value.objectValue,
                      let workspaceID = object["workspace_id"]?.stringValue else { return nil }
                let source = RaiWorkspaceReference(endpoint: machine.endpoint, workspaceID: workspaceID)
                return InstanceWorkspace(
                    id: source,
                    label: label(object, fallback: workspaceID),
                    instanceLabel: machine.label,
                    connectionID: machine.connectionID,
                    bootID: snapshot.bootID,
                    activeTabID: object["active_tab_id"]?.stringValue,
                    tabs: snapshot.tabs.compactMap { InstanceTab(record: $0, workspace: source, snapshot: snapshot) }
                )
            }
        }
    }

    fileprivate static func label(_ record: [String: JSONValue], fallback: String) -> String {
        let text = AgentTitleGlyphs.strip(record["label"]?.stringValue ?? "")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? fallback : text
    }
}

public struct InstanceTab: Identifiable, Equatable, Sendable {
    public let id: String
    public let workspace: RaiWorkspaceReference
    public let label: String
    public let status: AgentStatus
    public let panes: [RaiPaneReference]

    fileprivate init?(record: JSONValue, workspace: RaiWorkspaceReference, snapshot: HerdrEndpointSnapshot) {
        guard let object = record.objectValue,
              object["workspace_id"]?.stringValue == workspace.workspaceID,
              let tabID = object["tab_id"]?.stringValue else { return nil }
        id = tabID
        self.workspace = workspace
        label = InstanceWorkspace.label(object, fallback: tabID)
        status = AgentStatus(rawValue: object["agent_status"]?.stringValue ?? "") ?? .unknown
        panes = snapshot.panes.compactMap { value in
            guard let pane = value.objectValue,
                  pane["workspace_id"]?.stringValue == workspace.workspaceID,
                  pane["tab_id"]?.stringValue == tabID,
                  let paneID = pane["pane_id"]?.stringValue else { return nil }
            return RaiPaneReference(endpoint: workspace.endpoint, workspaceID: workspace.workspaceID,
                                    tabID: tabID, paneID: paneID)
        }
    }
}
