public enum AttentionFilter {
    public static func includes<ID: Equatable>(
        status: AgentStatus,
        id: ID,
        selectedID: ID?,
        onlyNeedsYou: Bool
    ) -> Bool {
        !onlyNeedsYou || status == .blocked || id == selectedID
    }
}
