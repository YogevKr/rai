/// Where a freshly created tab should land in its workspace's tab strip.
///
/// herdr's tab.create always appends to the end of the space; when creation
/// is anchored to an existing tab (the focused one, or the tab a context
/// menu was opened on), the created tab is tab.move'd to sit right after
/// that anchor — browser-style "open next to me".
public enum NewTabPlacement {
    /// Insert index for the created tab, or nil when no reorder is needed:
    /// no anchor, the anchor isn't in the target space, or the anchor is
    /// last and the append already landed the tab next to it.
    public static func insertIndex(
        tabs: [HerdrTab],
        workspaceID: String,
        afterTabID: String?
    ) -> Int? {
        guard let afterTabID else { return nil }
        let strip = tabs.filter { $0.workspaceID == workspaceID }
        guard let anchor = strip.firstIndex(where: { $0.tabID == afterTabID }),
              anchor + 1 < strip.count else {
            return nil
        }
        return anchor + 1
    }
}
