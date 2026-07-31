import Foundation

/// How the sidebar's agents panel orders its rows.
public enum AgentPanelSort: String, Codable, Sendable, CaseIterable {
    /// Agents that need you first, herd order within a band.
    case priority
    /// Herd order: spaces, then their tabs and panes.
    case grouped

    public var label: String { rawValue }

    public var toggled: AgentPanelSort {
        self == .priority ? .grouped : .priority
    }
}

/// One agent pane, flattened out of the space → tab → pane tree.
public struct AgentPanelEntry: Identifiable, Equatable, Sendable {
    public let paneID: String
    public let tabID: String
    public let workspaceID: String
    public let workspaceLabel: String
    /// nil when the tab name adds nothing — a lone auto-named tab in its space.
    public let tabLabel: String?
    /// nil for a pane with no detected agent (a plain shell).
    public let agentLabel: String?
    public let status: AgentStatus

    public var id: String { paneID }

    public init(
        paneID: String,
        tabID: String,
        workspaceID: String,
        workspaceLabel: String,
        tabLabel: String?,
        agentLabel: String?,
        status: AgentStatus
    ) {
        self.paneID = paneID
        self.tabID = tabID
        self.workspaceID = workspaceID
        self.workspaceLabel = workspaceLabel
        self.tabLabel = tabLabel
        self.agentLabel = agentLabel
        self.status = status
    }
}

public enum AgentPanel {
    /// Attention order, highest first: an agent waiting on you outranks one that
    /// finished, which outranks one still working.
    public static func attentionPriority(_ status: AgentStatus) -> Int {
        switch status {
        case .blocked: 4
        case .done: 3
        case .working: 2
        case .idle: 1
        case .unknown: 0
        }
    }

    public static func entries(
        in snapshot: SessionSnapshot,
        sort: AgentPanelSort
    ) -> [AgentPanelEntry] {
        let herdOrder = herdOrderEntries(in: snapshot)
        guard sort == .priority else { return herdOrder }
        // Sort(by:) is not guaranteed stable, and a list that reshuffles equal
        // rows on every snapshot is unusable — carry the herd index as the
        // tiebreaker rather than relying on the sort.
        return herdOrder.enumerated()
            .sorted { left, right in
                let leftRank = attentionPriority(left.element.status)
                let rightRank = attentionPriority(right.element.status)
                if leftRank != rightRank { return leftRank > rightRank }
                return left.offset < right.offset
            }
            .map(\.element)
    }

    private static func herdOrderEntries(
        in snapshot: SessionSnapshot
    ) -> [AgentPanelEntry] {
        if let agents = snapshot.agents {
            return agents.map { agent in
                let workspace = snapshot.workspaces.first {
                    $0.workspaceID == agent.workspaceID
                }
                let tab = snapshot.tabs.first { $0.tabID == agent.tabID }
                let tabCount = snapshot.tabs.lazy.filter {
                    $0.workspaceID == agent.workspaceID
                }.count
                let tabLabel = tab.flatMap {
                    tabCount > 1 || isNamed($0)
                        ? displayLabel(for: $0, agent: agent)
                        : nil
                }
                return AgentPanelEntry(
                    paneID: agent.paneID,
                    tabID: agent.tabID,
                    workspaceID: agent.workspaceID,
                    workspaceLabel: workspaceLabel(
                        workspace,
                        fallback: agent.workspaceID
                    ),
                    tabLabel: tabLabel,
                    agentLabel: trimmedAgent(agent.agent),
                    status: agent.agentStatus
                )
            }
        }
        return snapshot.workspaces.flatMap { workspace -> [AgentPanelEntry] in
            let tabs = snapshot.tabs.filter {
                $0.workspaceID == workspace.workspaceID
            }
            let showsTabLabel = tabs.count > 1
            return tabs.flatMap { tab -> [AgentPanelEntry] in
                let label = showsTabLabel || isNamed(tab)
                    ? snapshot.displayLabel(for: tab)
                    : nil
                return snapshot.panes
                    .filter { $0.tabID == tab.tabID }
                    .map { pane in
                        AgentPanelEntry(
                            paneID: pane.paneID,
                            tabID: tab.tabID,
                            workspaceID: workspace.workspaceID,
                            workspaceLabel: snapshot.workspaceLabel(for: pane),
                            tabLabel: label,
                            agentLabel: trimmedAgent(pane.agent),
                            status: pane.agentStatus
                        )
                    }
            }
        }
    }

    /// herdr auto-names a tab with its number; such a label is noise next to the
    /// space it already sits in.
    private static func isNamed(_ tab: HerdrTab) -> Bool {
        let label = tab.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return !label.isEmpty && Int(label) == nil
    }

    private static func displayLabel(
        for tab: HerdrTab,
        agent: HerdrAgent
    ) -> String {
        let label = tab.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !label.isEmpty, Int(label) == nil { return label }
        if let title = agent.terminalTitleStripped?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !title.isEmpty {
            return title
        }
        return trimmedAgent(agent.agent) ?? (label.isEmpty ? "shell" : label)
    }

    private static func workspaceLabel(
        _ workspace: Workspace?,
        fallback: String
    ) -> String {
        guard let workspace else { return fallback }
        let label = workspace.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? "Space \(workspace.number)" : label
    }

    private static func trimmedAgent(_ value: String?) -> String? {
        guard let agent = value?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !agent.isEmpty else {
            return nil
        }
        return agent
    }
}
