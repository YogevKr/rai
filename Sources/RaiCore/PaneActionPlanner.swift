public enum PaneActionPlanner {
    /// Builds the exact herdr CLI action for dropping one pane onto another.
    /// Same-tab drops swap leaves; cross-tab drops move the source beside the target.
    public static func dropArguments(
        sourcePaneID: String,
        sourceTabID: String,
        targetPaneID: String,
        targetTabID: String,
        moveDirection: SplitDirection
    ) -> [String]? {
        guard sourcePaneID != targetPaneID else { return nil }

        if sourceTabID == targetTabID {
            return [
                "pane", "swap",
                "--source-pane", sourcePaneID,
                "--target-pane", targetPaneID,
            ]
        }

        return [
            "pane", "move", sourcePaneID,
            "--tab", targetTabID,
            "--split", moveDirection.rawValue,
            "--target-pane", targetPaneID,
            "--no-focus",
        ]
    }

    public static func agentStartArguments(
        name: String,
        executable: String,
        direction: SplitDirection,
        cwd: String
    ) -> [String] {
        [
            "agent", "start", name,
            "--split", direction.rawValue,
            "--cwd", cwd,
            "--no-focus",
            "--", executable,
        ]
    }
}
