import Foundation

/// A background shell/monitor a Claude Code session has registered — work that
/// keeps running after the agent's turn ends and re-invokes it on completion.
/// While one of these is alive, an "idle" agent isn't finished; it's waiting.
public struct AgentBackgroundTask: Sendable, Equatable, Identifiable {
    public let pid: Int
    /// The human-readable definition (the command/loop the session registered).
    public let definition: String
    public var id: Int { pid }

    public init(pid: Int, definition: String) {
        self.pid = pid
        self.definition = definition
    }
}

/// Pure detection logic for a session's pending background work, from process
/// observations. Empirically verified against Claude Code 2.x:
///
/// - The harness runs every Bash tool command through
///   `/bin/zsh -c source ~/.claude/shell-snapshots/snapshot-zsh-….sh … && eval '<cmd>' …`
///   and background (`run_in_background`) tasks/monitors stay alive as direct
///   children of the pane's `claude` process after the turn ends.
/// - So: an idle claude with a live snapshot-shell child == pending background
///   work, and the child's command line carries the full definition.
public enum BackgroundWorkParser {
    public struct PSRow: Sendable {
        public let pid: Int
        public let ppid: Int
        public let command: String
        public init(pid: Int, ppid: Int, command: String) {
            self.pid = pid
            self.ppid = ppid
            self.command = command
        }
    }

    /// Finds the claude process in a pane's foreground process group.
    public static func claudePID(inCommandLines processes: [(pid: Int, cmdline: String)]) -> Int? {
        processes.first { process in
            let cmd = process.cmdline
            return cmd == "claude" || cmd.hasPrefix("claude ")
                || cmd.hasSuffix("/claude") || cmd.contains("/claude ")
        }?.pid
    }

    /// Filters a full `ps` listing down to harness-spawned background shells
    /// owned by the given claude process.
    public static func backgroundShells(
        psRows: [PSRow],
        claudePID: Int
    ) -> [AgentBackgroundTask] {
        psRows.filter { row in
            row.ppid == claudePID
                && row.command.contains(".claude/shell-snapshots/snapshot-")
                && (row.command.hasPrefix("/bin/zsh") || row.command.hasPrefix("zsh")
                    || row.command.hasPrefix("/bin/bash") || row.command.hasPrefix("bash"))
        }.map { AgentBackgroundTask(pid: $0.pid, definition: definition(fromShellCommand: $0.command)) }
    }

    /// Extracts the human-readable command from the harness's zsh wrapper:
    /// `zsh -c source <snapshot> && … && eval '<THE COMMAND>' < /dev/null && pwd …`.
    /// Falls back to the raw command when the wrapper shape isn't recognized.
    public static func definition(fromShellCommand raw: String) -> String {
        var text = raw
        if let evalRange = text.range(of: "eval '") {
            var payload = String(text[evalRange.upperBound...])
            // The wrapper's tail markers, outermost first.
            for terminator in ["' < /dev/null && pwd -P", "' < /dev/null"] {
                if let end = payload.range(of: terminator, options: .backwards) {
                    payload = String(payload[..<end.lowerBound])
                    break
                }
            }
            text = payload
        } else if let last = text.range(of: "&& ", options: .backwards) {
            text = String(text[last.upperBound...])
        }
        // ps renders embedded newlines as \012; shell-quoting doubles quotes.
        text = text.replacingOccurrences(of: "\\012", with: "\n")
        text = text.replacingOccurrences(of: "'\"'\"'", with: "'")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One-line summary of a definition, for compact UI.
    public static func summary(of definition: String, maxLength: Int = 90) -> String {
        let firstLine = definition
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? definition
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.count > maxLength
            ? String(trimmed.prefix(maxLength)) + "…"
            : trimmed
    }
}
