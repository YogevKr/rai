public struct PaneStatusTransition: Equatable, Sendable {
    public let paneID: String
    public let newStatus: AgentStatus

    public init(paneID: String, newStatus: AgentStatus) {
        self.paneID = paneID
        self.newStatus = newStatus
    }
}

public enum StatusTransitions {
    /// Returns panes that changed into a user-visible terminal agent state.
    ///
    /// New panes are not transitions: callers should seed their first observed
    /// status map, then diff subsequent snapshots.
    public static func detect(
        from oldStatuses: [String: AgentStatus],
        to newStatuses: [String: AgentStatus]
    ) -> [PaneStatusTransition] {
        newStatuses.keys.sorted().compactMap { paneID in
            guard let oldStatus = oldStatuses[paneID],
                  let newStatus = newStatuses[paneID],
                  oldStatus != newStatus,
                  newStatus == .blocked || newStatus == .done else {
                return nil
            }
            return PaneStatusTransition(paneID: paneID, newStatus: newStatus)
        }
    }
}
