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

    /// Updates from panes in sidebar order. Each eligible pane maps directly to
    /// the corresponding physical slot, capped at the six available slots.
    public mutating func update(
        _ panesInSidebarOrder: [MicroSlotAssignment],
        selectedPaneID: String? = nil,
        onlyNeedsYou: Bool = false
    ) -> [MicroSlotAssignment?] {
        var seenPaneIDs: Set<String> = []
        let assignments = panesInSidebarOrder.filter {
            seenPaneIDs.insert($0.paneID).inserted && AttentionFilter.includes(
                status: $0.status,
                id: $0.paneID,
                selectedID: selectedPaneID,
                onlyNeedsYou: onlyNeedsYou
            )
        }
        let assigned = Array(assignments.prefix(6))
        slots = assigned.map(\.paneID)
            + Array(repeating: nil, count: 6 - assigned.count)
        return assigned.map(Optional.some)
            + Array(repeating: nil, count: 6 - assigned.count)
    }

    public var paneIDsBySlot: [String?] { slots }
}
