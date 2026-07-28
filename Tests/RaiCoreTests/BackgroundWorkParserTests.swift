import RaiCore
import XCTest

final class BackgroundWorkParserTests: XCTestCase {
    // A real harness-spawned background watcher captured from `ps` on a live
    // Claude Code session (abridged snapshot path, real wrapper shape).
    private let realWatcher = """
    /bin/zsh -c source /Users/yogev/.claude/shell-snapshots/snapshot-zsh-1784998442195-4rxi6q.sh 2>/dev/null || true && : && setopt NO_EXTENDED_GLOB 2>/dev/null || true && eval 'prev_tip=""; first=1\\012while true; do\\012  tip=$(gh api "repos/x/y/commits?per_page=1" 2>/dev/null || true)\\012  sleep 180\\012done' < /dev/null && pwd -P >| /tmp/claude-2e2e-cwd
    """

    func testFindsClaudeInForegroundGroup() {
        let processes: [(pid: Int, cmdline: String)] = [
            (97515, "caffeinate -i -t 300"),
            (44944, "/Users/x/bin/python /Users/x/bin/hass-mcp"),
            (44763, "ssh mac-mini /opt/homebrew/bin/node server.js"),
            (44635, "claude --dangerously-skip-permissions --resume 9896ec1f"),
        ]
        XCTAssertEqual(BackgroundWorkParser.claudePID(inCommandLines: processes), 44635)
    }

    func testClaudePIDNilWhenNoClaude() {
        XCTAssertNil(BackgroundWorkParser.claudePID(inCommandLines: [
            (1, "/bin/zsh -il"), (2, "vim notes.md"),
        ]))
    }

    func testBackgroundShellDetectionRequiresSnapshotSignatureAndParent() {
        let rows = [
            BackgroundWorkParser.PSRow(pid: 39697, ppid: 36418, command: realWatcher),
            // MCP server child of claude — not a background task
            BackgroundWorkParser.PSRow(pid: 44944, ppid: 36418, command: "/usr/bin/python mcp-server"),
            // snapshot shell but different parent (another session's)
            BackgroundWorkParser.PSRow(pid: 57886, ppid: 47188, command: realWatcher),
        ]
        let tasks = BackgroundWorkParser.backgroundShells(psRows: rows, claudePID: 36418)
        XCTAssertEqual(tasks.map(\.pid), [39697])
    }

    func testDefinitionExtractsEvalPayloadAndDecodesNewlines() {
        let def = BackgroundWorkParser.definition(fromShellCommand: realWatcher)
        XCTAssertTrue(def.hasPrefix("prev_tip=\"\"; first=1"))
        XCTAssertTrue(def.contains("\nwhile true; do"))
        XCTAssertTrue(def.contains("sleep 180"))
        XCTAssertFalse(def.contains("shell-snapshots"))
        XCTAssertFalse(def.contains("pwd -P"))
    }

    func testDefinitionUnescapesShellQuoting() {
        let cmd = "/bin/zsh -c source /x/.claude/shell-snapshots/snapshot-zsh-1.sh && eval 'echo '\"'\"'hi'\"'\"'' < /dev/null && pwd -P >| /tmp/c"
        XCTAssertEqual(BackgroundWorkParser.definition(fromShellCommand: cmd), "echo 'hi'")
    }

    func testSummaryTruncatesToFirstLine() {
        XCTAssertEqual(
            BackgroundWorkParser.summary(of: "while true; do\n  poll\ndone"),
            "while true; do"
        )
        let long = String(repeating: "x", count: 200)
        XCTAssertEqual(BackgroundWorkParser.summary(of: long).count, 91) // 90 + ellipsis
    }
}
