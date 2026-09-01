import Foundation

public extension SessionSnapshot {
    /// A blank or numeric tab label carries no useful title. Prefer the same
    /// terminal/agent fallbacks used by the sidebar and command palette.
    func displayLabel(for tab: HerdrTab) -> String {
        if tab.hasUsefulLabel {
            return tab.label.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let tabPanes = panes.filter { $0.tabID == tab.tabID }
        if let title = tabPanes.compactMap(\.terminalTitleStripped)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return title
        }
        if let agent = tabPanes.compactMap(\.agent)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return agent
        }
        return "shell"
    }

    /// Pane-first naming for notifications and pane chrome.
    func displayName(for pane: Pane) -> String {
        if let title = pane.terminalTitleStripped?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        if let agent = pane.agent?.trimmingCharacters(in: .whitespacesAndNewlines),
           !agent.isEmpty {
            return agent
        }
        if let tab = tabs.first(where: { $0.tabID == pane.tabID }) {
            let label = tab.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if !label.isEmpty { return label }
        }
        return pane.paneID
    }

    func workspaceLabel(for pane: Pane) -> String {
        guard let workspace = workspaces.first(where: {
            $0.workspaceID == pane.workspaceID
        }) else {
            return pane.workspaceID
        }
        let label = workspace.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? "Space \(workspace.number)" : label
    }
}
