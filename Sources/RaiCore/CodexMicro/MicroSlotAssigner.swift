public struct MicroSlotAssignment: Equatable, Sendable {
    public let paneID: String
    public let status: AgentStatus

    public init(paneID: String, status: AgentStatus) {
        self.paneID = paneID
        self.status = status
    }
}

public struct MicroSlotAssigner: @unchecked Sendable {
    private var recency = LRUTracker<String>(capacity: 6)
    private var slots: [String?] = Array(repeating: nil, count: 6)

    public init() {}

    /// Updates from panes ordered most-recent-first. Existing eligible panes retain
    /// their physical slot; newly eligible panes fill empty slots in recency order.
    public mutating func update(
        _ panesMostRecentFirst: [MicroSlotAssignment],
        selectedPaneID: String? = nil,
        onlyNeedsYou: Bool = false
    ) -> [MicroSlotAssignment?] {
        var statuses: [String: AgentStatus] = [:]
        var orderedIDs: [String] = []
        for pane in panesMostRecentFirst where statuses[pane.paneID] == nil {
            guard AttentionFilter.includes(
                status: pane.status,
                id: pane.paneID,
                selectedID: selectedPaneID,
                onlyNeedsYou: onlyNeedsYou
            ) else { continue }
            statuses[pane.paneID] = pane.status
            orderedIDs.append(pane.paneID)
        }

        let desired = Set(orderedIDs.prefix(6))
        for index in slots.indices {
            if let paneID = slots[index], !desired.contains(paneID) {
                slots[index] = nil
                recency.remove(paneID)
            }
        }
        for paneID in orderedIDs.prefix(6).reversed() {
            _ = recency.touch(paneID)
        }
        let assigned = Set(slots.compactMap { $0 })
        var newcomers = orderedIDs.prefix(6).filter { !assigned.contains($0) }[...]
        for index in slots.indices where slots[index] == nil && !newcomers.isEmpty {
            slots[index] = newcomers.removeFirst()
        }
        return slots.map { paneID in
            paneID.flatMap { id in
                statuses[id].map { MicroSlotAssignment(paneID: id, status: $0) }
            }
        }
    }

    public var paneIDsBySlot: [String?] { slots }
}
