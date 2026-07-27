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
            "--",
        ] + shellFallbackArgv(executable)
    }

    /// Wraps an agent command line so the pane outlives the agent. herdr execs
    /// this argv as the pane's root process, so a bare agent binary would take
    /// the pane — and a single-pane tab — down with it when the user exits the
    /// agent. Falling back to the user's interactive shell keeps the pane open
    /// at a prompt instead, matching what exiting an agent started by hand in
    /// a terminal does.
    public static func shellFallbackArgv(_ command: String) -> [String] {
        ["/bin/sh", "-lc", "\(command); exec \"${SHELL:-/bin/sh}\" -l"]
    }

    /// Builds the non-splitting agent launch used by remote companions.
    public static func agentStartArguments(
        name: String,
        executable: String,
        workspaceID: String?,
        cwd: String?
    ) -> [String] {
        var arguments = ["agent", "start", name]
        if let workspaceID {
            arguments += ["--workspace", workspaceID]
        }
        if let cwd {
            arguments += ["--cwd", cwd]
        }
        arguments += ["--no-focus", "--", executable]
        return arguments
    }
}
