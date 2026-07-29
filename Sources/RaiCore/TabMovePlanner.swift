/// Plans relocating a whole tab into another (or a new) workspace.
///
/// herdr's tab.move only reorders tabs inside their workspace, so a
/// cross-space move is a pane.move sequence: the lead pane rides a
/// `new_tab`/`new_workspace` destination (which creates the landing tab), and
/// every remaining pane follows into that tab. Split geometry is not
/// preserved — herdr has no way to transplant a layout across workspaces.
public enum TabMovePlanner {
    public struct Plan: Equatable, Sendable {
        public let leadPaneID: String
        public let followerPaneIDs: [String]
        /// The tab label to re-apply on the landing tab, or nil when the label
        /// is herdr's auto-numbering and should be re-derived at the target.
        public let carriedLabel: String?
    }

    public static func plan(
        tab: HerdrTab,
        panes: [Pane],
        layout: PaneLayoutSnapshot?
    ) -> Plan? {
        let ordered = orderedPaneIDs(tabID: tab.tabID, panes: panes, layout: layout)
        guard let lead = ordered.first else { return nil }
        return Plan(
            leadPaneID: lead,
            followerPaneIDs: Array(ordered.dropFirst()),
            carriedLabel: carriedLabel(for: tab)
        )
    }

    /// Same auto-label heuristic as SessionSnapshot.displayLabel: a blank or
    /// purely numeric label is herdr's numbering, not a user-chosen name, and
    /// pinning it onto the new tab would freeze a stale number.
    public static func carriedLabel(for tab: HerdrTab) -> String? {
        let trimmed = tab.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, Int(trimmed) == nil else { return nil }
        return trimmed
    }

    /// Layout reading order (top-to-bottom, then left-to-right) so the
    /// rebuilt tab lists panes the way the user saw them; panes the layout
    /// doesn't know about keep their snapshot order at the end.
    static func orderedPaneIDs(
        tabID: String,
        panes: [Pane],
        layout: PaneLayoutSnapshot?
    ) -> [String] {
        let tabPaneIDs = panes.filter { $0.tabID == tabID }.map(\.paneID)
        guard let layout, layout.tabID == tabID else { return tabPaneIDs }
        let known = Set(tabPaneIDs)
        let laidOut = layout.panes
            .filter { known.contains($0.paneID) }
            .sorted {
                ($0.rect.y, $0.rect.x) < ($1.rect.y, $1.rect.x)
            }
            .map(\.paneID)
        let placed = Set(laidOut)
        return laidOut + tabPaneIDs.filter { !placed.contains($0) }
    }
}
