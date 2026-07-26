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

    /// Assigns the six keys in stable sidebar order — the first six eligible
    /// panes, in the order they appear in the sidebar. A key's position never
    /// changes as agents' statuses change (that's the LED's job, via colour), so
    /// the pad never shifts a target out from under your finger. This mirrors the
    /// Codex Micro's own model: fixed key positions, status shown by colour, and
    /// the dial to reach anything past the sixth. The optional "only needs you"
    /// filter narrows the eligible set but keeps that set in sidebar order.
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
        let assigned = Array(eligible.prefix(6))
        slots = assigned.map(\.paneID)
            + Array(repeating: nil, count: 6 - assigned.count)
        return assigned.map(Optional.some)
            + Array(repeating: nil, count: 6 - assigned.count)
    }

    public var paneIDsBySlot: [String?] { slots }
}
