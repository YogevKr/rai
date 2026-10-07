import Foundation

/// A live Herdr space in the regular sidebar, identified by its owning instance.
public struct InstanceWorkspace: Identifiable, Equatable, Sendable {
    public let id: RaiWorkspaceReference
    public let label: String
    public let instanceLabel: String
    /// The saved machine target lets the sidebar identify an ad-hoc remote
    /// connection that points at the same instance.
    public let instanceTarget: String?
    public let connectionID: String?
    public let bootID: String
    public let activeTabID: String?
    public let tabs: [InstanceTab]

    /// A dismissed tab stays on Herdr. Filter only this server incarnation.
    public func excludingDismissedTabs(_ dismissed: [RaiDismissedTab]) -> InstanceWorkspace? {
        let hidden = Set(dismissed.filter { $0.workspace == id && $0.bootID == bootID }.map(\.tabID))
        let visible = tabs.filter { !hidden.contains($0.id) }
        guard !visible.isEmpty || tabs.isEmpty else { return nil }
        return InstanceWorkspace(id: id, label: label, instanceLabel: instanceLabel,
            instanceTarget: instanceTarget, connectionID: connectionID, bootID: bootID,
            activeTabID: visible.first { $0.id == activeTabID }?.id ?? visible.first?.id,
            tabs: visible)
    }

    public static func entries(
        machines: [MachineEntry],
        snapshots: [MachineEndpoint: HerdrEndpointSnapshot],
        excluding primary: MachineEndpoint?,
        titleSnapshots: [MachineEndpoint: SessionSnapshot] = [:]
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
                    instanceTarget: machine.target,
                    connectionID: machine.connectionID,
                    bootID: snapshot.bootID,
                    activeTabID: object["active_tab_id"]?.stringValue,
                    tabs: snapshot.tabs.compactMap {
                        InstanceTab(record: $0, workspace: source, snapshot: snapshot,
                                    titleSnapshot: titleSnapshots[machine.endpoint])
                    }
                )
            }
        }
    }

    /// Returns true when this source workspace belongs to the active machine.
    /// A direct remote connection uses an ad-hoc endpoint, so endpoint equality
    /// alone cannot identify the same saved machine.
    public func belongs(to machine: MachineEntry?) -> Bool {
        guard let machine else { return false }
        if id.endpoint == machine.endpoint { return true }
        return instanceTarget != nil
            && instanceTarget == machine.target
            && id.endpoint.session == machine.endpoint.session
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
    public let context: String
    public let status: AgentStatus
    public let panes: [RaiPaneReference]

    fileprivate init?(record: JSONValue, workspace: RaiWorkspaceReference, snapshot: HerdrEndpointSnapshot,
                      titleSnapshot: SessionSnapshot?) {
        guard let object = record.objectValue,
              object["workspace_id"]?.stringValue == workspace.workspaceID,
              let tabID = object["tab_id"]?.stringValue else { return nil }
        id = tabID
        self.workspace = workspace
        let pane = snapshot.panes.first { value in
            guard let pane = value.objectValue else { return false }
            return pane["workspace_id"]?.stringValue == workspace.workspaceID
                && pane["tab_id"]?.stringValue == tabID
        }?.objectValue
        let cwd = pane?["cwd"]?.stringValue ?? pane?["foreground_cwd"]?.stringValue ?? ""
        context = cwd.isEmpty ? "" : URL(fileURLWithPath: cwd).lastPathComponent
        status = AgentStatus(rawValue: object["agent_status"]?.stringValue ?? "") ?? .unknown
        panes = snapshot.panes.compactMap { value in
            guard let pane = value.objectValue,
                  pane["workspace_id"]?.stringValue == workspace.workspaceID,
                  pane["tab_id"]?.stringValue == tabID,
                  let paneID = pane["pane_id"]?.stringValue else { return nil }
            return RaiPaneReference(endpoint: workspace.endpoint, workspaceID: workspace.workspaceID,
                                    tabID: tabID, paneID: paneID)
        }
        // The inactive endpoint can defer title-only projections. Read-only API
        // metadata supplies current labels, but never changes the endpoint's
        // resource set, focus, revision, or render identity.
        if let titleSnapshot,
           let tab = titleSnapshot.tabs.first(where: { $0.tabID == tabID && $0.workspaceID == workspace.workspaceID }),
           Set(titleSnapshot.panes.filter { $0.tabID == tabID && $0.workspaceID == workspace.workspaceID }.map(\.paneID))
            == Set(panes.map(\.paneID)) {
            label = titleSnapshot.displayLabel(for: tab)
        } else {
            label = Self.tabLabel(object, workspaceID: workspace.workspaceID, tabID: tabID, snapshot: snapshot)
        }
    }

    fileprivate static func tabLabel(
        _ record: [String: JSONValue],
        workspaceID: String,
        tabID: String,
        snapshot: HerdrEndpointSnapshot
    ) -> String {
        let raw = AgentTitleGlyphs.strip(record["label"]?.stringValue ?? "")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !raw.isEmpty && Int(raw) == nil { return raw }

        let panes = snapshot.panes.compactMap(\.objectValue).filter {
            $0["workspace_id"]?.stringValue == workspaceID && $0["tab_id"]?.stringValue == tabID
        }
        // Native endpoint panes contain identity and cwd. Titles and agent
        // names live in the separate agent projection. Match all identities
        // so an old or unrelated record cannot supply this tab's title.
        let paneIDs = Set(panes.compactMap { $0["pane_id"]?.stringValue })
        let agents = snapshot.agents.compactMap(\.objectValue).filter {
            $0["workspace_id"]?.stringValue == workspaceID
                && $0["tab_id"]?.stringValue == tabID
                && $0["pane_id"]?.stringValue.map(paneIDs.contains) == true
        }
        let records = agents + panes
        for key in ["terminal_title_stripped", "terminal_title"] {
            for record in records {
                if let title = TerminalDisplayTitle.text(record[key]?.stringValue, agent: record["agent"]?.stringValue) {
                    return title
                }
            }
        }
        for record in records {
            let agent = record["agent"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !agent.isEmpty {
                return agent
            }
        }
        return "shell"
    }
}
