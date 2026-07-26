import Foundation

public indirect enum PaneLayoutNode: Sendable, Equatable {
    case pane(String)
    case split(
        id: String,
        direction: SplitDirection,
        ratio: Double,
        first: PaneLayoutNode,
        second: PaneLayoutNode
    )

    public var paneIDs: [String] {
        switch self {
        case .pane(let paneID):
            [paneID]
        case .split(_, _, _, let first, let second):
            first.paneIDs + second.paneIDs
        }
    }
}

public enum PaneLayoutTreeBuilder {
    public static func build(from layout: PaneLayoutSnapshot) -> PaneLayoutNode? {
        guard !layout.panes.isEmpty else { return nil }
        if layout.panes.count == 1 {
            return .pane(layout.panes[0].paneID)
        }

        let splitsByRect = Dictionary(
            grouping: layout.splits,
            by: \.rect
        )
        let panesByRect = Dictionary(
            grouping: layout.panes,
            by: \.rect
        )
        var usedSplitIDs = Set<String>()

        func build(region: PaneLayoutRect) -> PaneLayoutNode? {
            if let split = splitsByRect[region]?
                .first(where: { !usedSplitIDs.contains($0.id) }) {
                guard let (firstRect, secondRect) = childRects(
                    for: region,
                    direction: split.direction,
                    ratio: split.ratio
                ) else {
                    return nil
                }
                usedSplitIDs.insert(split.id)
                guard let first = build(region: firstRect),
                      let second = build(region: secondRect) else {
                    return nil
                }
                return .split(
                    id: split.id,
                    direction: split.direction,
                    ratio: clamped(split.ratio),
                    first: first,
                    second: second
                )
            }

            if let pane = panesByRect[region]?.first {
                return .pane(pane.paneID)
            }

            let contained = layout.panes.filter { region.contains($0.rect) }
            if contained.count == 1 {
                return .pane(contained[0].paneID)
            }
            return nil
        }

        guard let root = build(region: layout.area),
              Set(root.paneIDs) == Set(layout.panes.map(\.paneID)) else {
            return nil
        }
        return root
    }

    private static func childRects(
        for rect: PaneLayoutRect,
        direction: SplitDirection,
        ratio: Double
    ) -> (PaneLayoutRect, PaneLayoutRect)? {
        let ratio = clamped(ratio)
        switch direction {
        case .right:
            guard rect.width >= 2 else { return nil }
            let firstWidth = max(
                1,
                min(rect.width - 1, Int((Double(rect.width) * ratio).rounded()))
            )
            return (
                PaneLayoutRect(
                    x: rect.x,
                    y: rect.y,
                    width: firstWidth,
                    height: rect.height
                ),
                PaneLayoutRect(
                    x: rect.x + firstWidth,
                    y: rect.y,
                    width: rect.width - firstWidth,
                    height: rect.height
                )
            )
        case .down:
            guard rect.height >= 2 else { return nil }
            let firstHeight = max(
                1,
                min(rect.height - 1, Int((Double(rect.height) * ratio).rounded()))
            )
            return (
                PaneLayoutRect(
                    x: rect.x,
                    y: rect.y,
                    width: rect.width,
                    height: firstHeight
                ),
                PaneLayoutRect(
                    x: rect.x,
                    y: rect.y + firstHeight,
                    width: rect.width,
                    height: rect.height - firstHeight
                )
            )
        }
    }

    private static func clamped(_ ratio: Double) -> Double {
        min(0.95, max(0.05, ratio))
    }
}
