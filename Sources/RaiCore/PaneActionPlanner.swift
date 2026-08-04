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

    /// herdr ≥0.7.5 removed `agent start --split/--workspace/--tab`: an agent
    /// now starts by typing its command into an existing pane at a shell
    /// prompt. These planners build the hosting pane; the caller waits for
    /// the shell, then types the launch command with `pane run`. The shell
    /// stays underneath the agent, so the pane survives the agent exiting.
    public static func agentSplitArguments(
        paneID: String,
        direction: SplitDirection,
        cwd: String
    ) -> [String] {
        [
            "pane", "split", paneID,
            "--direction", direction.rawValue,
            "--cwd", cwd,
            "--no-focus",
        ]
    }

    /// Builds the non-splitting agent host tab used by remote companions.
    public static func agentTabCreateArguments(
        workspaceID: String,
        cwd: String?
    ) -> [String] {
        var arguments = ["tab", "create", "--workspace", workspaceID]
        if let cwd {
            arguments += ["--cwd", cwd]
        }
        arguments.append("--no-focus")
        return arguments
    }

    /// A fresh, no-resume agent launch: herdr waits for the pane's shell
    /// prompt and the agent's own readiness internally, so this needs no
    /// guessed delay and no `pane run` typing race. Only good for a bare
    /// launch — herdr execs the kind's canonical binary directly with these
    /// trailing args, so it cannot carry a `first || fallback` shell
    /// invocation (see `resumeCommand` for why reopen can't use this).
    public static func agentStartArguments(
        name: String,
        kind: String,
        paneID: String
    ) -> [String] {
        ["agent", "start", name, "--kind", kind, "--pane", paneID]
    }
}
