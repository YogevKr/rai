import RaiCore
import XCTest
@testable import rai

final class HerdListLayoutTests: XCTestCase {
    func testTriageOnShowsGroups() {
        XCTAssertEqual(
            HerdListLayout.resolve(triageEnabled: true, filter: nil),
            .triage
        )
    }

    func testTriageOnWithFilterShowsOneFlatSection() {
        XCTAssertEqual(
            HerdListLayout.resolve(triageEnabled: true, filter: .working),
            .filtered(.working)
        )
    }

    func testTriageOffIsJustTheSpaces() {
        XCTAssertEqual(
            HerdListLayout.resolve(triageEnabled: false, filter: nil),
            .plain
        )
    }

    func testTriageOffIgnoresAStaleFilter() {
        // A segment tapped before the toggle went off must not resurface a
        // filtered view on a screen that no longer shows the pulse line.
        XCTAssertEqual(
            HerdListLayout.resolve(triageEnabled: false, filter: .needsYou),
            .plain
        )
    }

    func testDefaultsKeyIsStable() {
        // Persisted on the device; renaming it would silently reset users.
        XCTAssertEqual(HerdListLayout.triageDefaultsKey, "triageGroupsEnabled")
    }

    func testPaneSecondaryTextUsesPendingPermissionTool() throws {
        let pane = try decodePane(beacon: """
        {
          "event":"PermissionRequest",
          "session_id":"session-1",
          "cwd":"/repo",
          "transcript_path":"/tmp/session.jsonl",
          "tool_name":"Bash",
          "tool_input":{"command":"swift test"},
          "ts":1
        }
        """)

        XCTAssertEqual(PaneRowSecondaryText.resolve(pane), "Bash: swift test")
    }

    func testPaneSecondaryTextUsesFirstBeaconQuestion() throws {
        let pane = try decodePane(beacon: """
        {
          "event":"PreToolUse",
          "session_id":"session-1",
          "cwd":"/repo",
          "transcript_path":"/tmp/session.jsonl",
          "tool_name":"AskUserQuestion",
          "tool_input":{"questions":[{"question":"Which target?"}]},
          "ts":1
        }
        """)

        XCTAssertEqual(PaneRowSecondaryText.resolve(pane), "Which target?")
    }

    private func decodePane(beacon: String) throws -> Pane {
        let json = """
        {
          "pane_id":"pane-1",
          "terminal_id":"terminal-1",
          "workspace_id":"workspace-1",
          "tab_id":"tab-1",
          "focused":false,
          "cwd":"/repo/project",
          "agent":"claude",
          "agent_status":"blocked",
          "revision":1,
          "beacon":\(beacon)
        }
        """
        return try JSONDecoder().decode(Pane.self, from: Data(json.utf8))
    }
}
