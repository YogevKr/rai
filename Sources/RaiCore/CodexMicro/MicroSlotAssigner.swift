public struct MicroSlotAssignment: Equatable, Sendable {
    public let paneID: String
    public let status: AgentStatus

    public init(paneID: String, status: AgentStatus) {
        self.paneID = paneID
        self.status = status
    }
}

public struct MicroSlotAssigner: @unchecked Sendable {
    private var slots: [String?] = Array(repeating: nil, count: 6)

    public init() {}

    /// Attention rank for a pane: lower wins a key first. A blocked or finished
    /// agent must never lose its key to an idle one, so the six physical keys
    /// hold the agents that most need you rather than simply the first six in
    /// the sidebar. The focused pane is boosted to at least the working tier so
    /// the agent you're actively driving keeps its key while others sit idle.
    private static func rank(
        _ assignment: MicroSlotAssignment,
        selectedPaneID: String?
    ) -> Int {
        let base: Int
        switch assignment.status {
        case .blocked: base = 0
        case .done: base = 1
        case .working: base = 2
        case .idle, .unknown: base = 3
        }
        return assignment.paneID == selectedPaneID ? min(base, 2) : base
    }

    /// Updates from panes in sidebar order, then ranks them attention-first so
    /// the six keys always hold the agents that most need you. Ties keep sidebar
    /// order, so a pane only shifts when its status tier changes.
    public mutating func update(
        _ panesInSidebarOrder: [MicroSlotAssignment],
        selectedPaneID: String? = nil,
        onlyNeedsYou: Bool = false
    ) -> [MicroSlotAssignment?] {
        var seenPaneIDs: Set<String> = []
        let eligible = panesInSidebarOrder.filter {
            seenPaneIDs.insert($0.paneID).inserted && AttentionFilter.includes(
                status: $0.status,
                id: $0.paneID,
                selectedID: selectedPaneID,
                onlyNeedsYou: onlyNeedsYou
            )
        }
        let ranked = eligible.enumerated()
            .sorted { lhs, rhs in
                let lRank = Self.rank(lhs.element, selectedPaneID: selectedPaneID)
                let rRank = Self.rank(rhs.element, selectedPaneID: selectedPaneID)
                return lRank == rRank ? lhs.offset < rhs.offset : lRank < rRank
            }
            .map(\.element)
        let assigned = Array(ranked.prefix(6))
        slots = assigned.map(\.paneID)
            + Array(repeating: nil, count: 6 - assigned.count)
        return assigned.map(Optional.some)
            + Array(repeating: nil, count: 6 - assigned.count)
    }

    public var paneIDsBySlot: [String?] { slots }
}
