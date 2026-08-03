/// One `pane split` needed to rebuild a closed tab's layout. Leaves are
/// numbered by the tree's left-to-right pane order; the tab's first pane is
/// leaf 0, and each step's new pane becomes `newLeaf`.
public struct TabRebuildStep: Equatable, Sendable, Codable {
    /// Leaf whose live pane gets split — the first leaf of the subtree that
    /// occupies the region being divided.
    public let anchorLeaf: Int
    public let newLeaf: Int
    public let direction: SplitDirection
    /// The FIRST child's share of the region — herdr's own split-ratio
    /// meaning, both in layout snapshots and in `pane split --ratio`, so the
    /// recorded value replays verbatim.
    public let ratio: Double

    public init(anchorLeaf: Int, newLeaf: Int, direction: SplitDirection, ratio: Double) {
        self.anchorLeaf = anchorLeaf
        self.newLeaf = newLeaf
        self.direction = direction
        self.ratio = ratio
    }
}

/// Turns a pane layout tree into the ordered splits that recreate it.
///
/// Replay mirrors how herdr grows its BSP tree: splitting a pane wraps it as
/// the FIRST child and puts the new pane SECOND. Emitting splits pre-order —
/// each subtree's region divided before the subtree is subdivided — therefore
/// reproduces the recorded tree exactly, anchors staying valid because a
/// region's first leaf is created before the region is ever divided.
public enum TabShapePlanner {
    public static func steps(for tree: PaneLayoutNode) -> [TabRebuildStep] {
        var leafIndex: [String: Int] = [:]
        for (index, paneID) in tree.paneIDs.enumerated() {
            leafIndex[paneID] = index
        }

        func firstLeaf(_ node: PaneLayoutNode) -> Int? {
            node.paneIDs.first.flatMap { leafIndex[$0] }
        }

        var steps: [TabRebuildStep] = []
        func emit(_ node: PaneLayoutNode) {
            guard case .split(_, let direction, let ratio, let first, let second) = node else {
                return
            }
            if let anchor = firstLeaf(first), let new = firstLeaf(second) {
                steps.append(
                    TabRebuildStep(
                        anchorLeaf: anchor,
                        newLeaf: new,
                        direction: direction,
                        ratio: ratio
                    )
                )
            }
            emit(first)
            emit(second)
        }
        emit(tree)
        return steps
    }
}
