import Foundation

public extension SessionSnapshot {
    /// A blank or numeric tab label carries no useful title. Prefer the same
    /// terminal/agent fallbacks used by the sidebar and command palette.
    func displayLabel(for tab: HerdrTab) -> String {
        let trimmed = tab.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, Int(trimmed) == nil { return trimmed }

        let tabPanes = panes.filter { $0.tabID == tab.tabID }
        if let title = tabPanes.compactMap(\.terminalTitleStripped)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return title
        }
        if let agent = tabPanes.compactMap(\.agent)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return agent
        }
        return trimmed.isEmpty ? "shell" : trimmed
    }
}
