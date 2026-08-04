import XCTest
@testable import RaiCore

final class HerdrModelsTests: XCTestCase {
    func testSnapshotDecodesAgentSessionsAndWorktreeIdentity() throws {
        let snapshot = try decode(
            """
            {
              "version":"0.7.4","protocol":16,
              "focused_workspace_id":"w1","focused_tab_id":"w1:t1",
              "focused_pane_id":"w1:p1",
              "workspaces":[{
                "workspace_id":"w1","number":1,"label":"rai","focused":true,
                "pane_count":1,"tab_count":1,"active_tab_id":"w1:t1",
                "agent_status":"working",
                "worktree":{
                  "repo_key":"/repo/rai/.git","repo_name":"rai",
                  "repo_root":"/repo/rai","checkout_path":"/repo/rai",
                  "is_linked_worktree":false
                }
              }],
              "tabs":[{
                "tab_id":"w1:t1","workspace_id":"w1","number":1,"label":"1",
                "focused":true,"pane_count":1,"agent_status":"working"
              }],
              "panes":[{
                "pane_id":"w1:p1","terminal_id":"term-1","workspace_id":"w1",
                "tab_id":"w1:t1","focused":true,"cwd":"/repo/rai",
                "agent":"claude","agent_status":"working","revision":2,
                "agent_session":{
                  "agent":"claude","kind":"id","source":"herdr:claude",
                  "value":"8f7de40b-d7c6-4c08-8890-7f7e87ef32aa"
                }
              }],
              "agents":[{
                "terminal_id":"term-1","agent":"claude",
                "terminal_title":"Claude Code","terminal_title_stripped":"Claude Code",
                "agent_status":"working","workspace_id":"w1","tab_id":"w1:t1",
                "pane_id":"w1:p1","focused":true,"cwd":"/repo/rai","revision":2,
                "agent_session":{
                  "agent":"claude","kind":"id","source":"herdr:claude",
                  "value":"8f7de40b-d7c6-4c08-8890-7f7e87ef32aa"
                }
              }],
              "layouts":[]
            }
            """
        )

        XCTAssertEqual(snapshot.agents?.count, 1)
        XCTAssertEqual(snapshot.agents?.first?.paneID, "w1:p1")
        XCTAssertEqual(snapshot.agents?.first?.agentSession?.kind, .id)
        XCTAssertEqual(snapshot.panes.first?.agentSession?.source, "herdr:claude")
        XCTAssertEqual(
            snapshot.panes.first?.agentSession?.value,
            "8f7de40b-d7c6-4c08-8890-7f7e87ef32aa"
        )
        XCTAssertEqual(snapshot.workspaces.first?.worktree?.repoKey, "/repo/rai/.git")
        XCTAssertEqual(snapshot.workspaces.first?.worktree?.repoRoot, "/repo/rai")
    }

    func testSnapshotWithoutAdditiveFieldsStillDecodes() throws {
        let snapshot = try decode(
            """
            {
              "version":"0.7.3","protocol":16,
              "focused_workspace_id":null,"focused_tab_id":null,
              "focused_pane_id":null,
              "workspaces":[{
                "workspace_id":"w1","number":1,"label":"rai","focused":true,
                "pane_count":1,"tab_count":1,"active_tab_id":"w1:t1",
                "agent_status":"idle",
                "worktree":{
                  "repo_name":"rai","checkout_path":"/repo/rai",
                  "is_linked_worktree":false
                }
              }],
              "tabs":[{
                "tab_id":"w1:t1","workspace_id":"w1","number":1,"label":"1",
                "focused":true,"pane_count":1,"agent_status":"idle"
              }],
              "panes":[{
                "pane_id":"w1:p1","terminal_id":"term-1","workspace_id":"w1",
                "tab_id":"w1:t1","focused":true,"cwd":"/repo/rai",
                "agent":null,"agent_status":"idle","revision":1
              }],
              "layouts":[]
            }
            """
        )

        XCTAssertNil(snapshot.agents)
        XCTAssertNil(snapshot.panes.first?.agentSession)
        XCTAssertNil(snapshot.workspaces.first?.worktree?.repoKey)
        XCTAssertNil(snapshot.workspaces.first?.worktree?.repoRoot)
    }

    func testClaudeExactResumeKeepsFlagsAndDropsContinue() {
        let session = AgentSession(
            agent: "claude",
            kind: .id,
            source: "herdr:claude",
            value: "session-id"
        )
        XCTAssertEqual(
            session.exactResumePlan(
                argv: ["claude", "--model", "opus", "--continue"]
            ),
            AgentResumePlan(
                resumeArgv: ["claude", "--model", "opus", "--resume", "session-id"],
                fallbackArgv: ["claude", "--model", "opus"]
            )
        )
    }

    func testClaudeBareResumeKeepsFollowingOptions() {
        let session = AgentSession(
            agent: "claude",
            kind: .id,
            source: "herdr:claude",
            value: "session-id"
        )
        XCTAssertEqual(
            session.exactResumePlan(
                argv: ["claude", "--resume", "--model", "opus"]
            ),
            AgentResumePlan(
                resumeArgv: ["claude", "--model", "opus", "--resume", "session-id"],
                fallbackArgv: ["claude", "--model", "opus"]
            )
        )
    }

    func testClaudeExactResumeDropsConsumedPrompt() {
        let session = AgentSession(
            agent: "claude",
            kind: .id,
            source: "herdr:claude",
            value: "session-id"
        )
        XCTAssertEqual(
            session.exactResumePlan(
                argv: ["claude", "--model", "opus", "fix this"]
            ),
            AgentResumePlan(
                resumeArgv: ["claude", "--model", "opus", "--resume", "session-id"],
                fallbackArgv: ["claude", "--model", "opus"]
            )
        )
    }

    func testClaudeExactResumeDropsForcedSessionIdentity() {
        let session = AgentSession(
            agent: "claude",
            kind: .id,
            source: "herdr:claude",
            value: "session-id"
        )
        XCTAssertEqual(
            session.exactResumePlan(
                argv: [
                    "claude", "--session-id", "session-id",
                    "--fork-session", "--model", "opus",
                ]
            ),
            AgentResumePlan(
                resumeArgv: ["claude", "--model", "opus", "--resume", "session-id"],
                fallbackArgv: ["claude", "--model", "opus"]
            )
        )
    }

    func testCodexExactResumeReplacesLastSessionLookup() {
        let session = AgentSession(
            agent: "codex",
            kind: .id,
            source: "herdr:codex",
            value: "session-id"
        )
        XCTAssertEqual(
            session.exactResumePlan(
                argv: ["codex", "resume", "--last", "--model", "o3"]
            ),
            AgentResumePlan(
                resumeArgv: ["codex", "resume", "session-id", "--model", "o3"],
                fallbackArgv: ["codex", "--model", "o3"]
            )
        )
    }

    func testCodexExactResumeReplacesOldIDAndKeepsOptions() {
        let session = AgentSession(
            agent: "codex",
            kind: .id,
            source: "herdr:codex",
            value: "session-id"
        )
        XCTAssertEqual(
            session.exactResumePlan(
                argv: ["codex", "resume", "session-id", "--model", "o3"]
            ),
            AgentResumePlan(
                resumeArgv: ["codex", "resume", "session-id", "--model", "o3"],
                fallbackArgv: ["codex", "--model", "o3"]
            )
        )
    }

    func testCodexExactResumeReplacesNamedSessionWithResolvedID() {
        let session = AgentSession(
            agent: "codex",
            kind: .id,
            source: "herdr:codex",
            value: "resolved-id"
        )
        XCTAssertEqual(
            session.exactResumePlan(
                argv: ["codex", "resume", "--model", "o3", "project-name"]
            ),
            AgentResumePlan(
                resumeArgv: ["codex", "resume", "resolved-id", "--model", "o3"],
                fallbackArgv: ["codex", "--model", "o3"]
            )
        )
    }

    func testCodexExactResumePlacesSubcommandBeforeRootPrompt() {
        let session = AgentSession(
            agent: "codex",
            kind: .id,
            source: "herdr:codex",
            value: "resolved-id"
        )
        XCTAssertEqual(
            session.exactResumePlan(
                argv: ["codex", "--model", "o3", "fix this"]
            ),
            AgentResumePlan(
                resumeArgv: ["codex", "--model", "o3", "resume", "resolved-id"],
                fallbackArgv: ["codex", "--model", "o3"]
            )
        )
    }

    func testExactResumeRejectsUnofficialSessionSource() {
        let session = AgentSession(
            agent: "claude",
            kind: .id,
            source: "plugin:claude",
            value: "session-id"
        )
        XCTAssertNil(session.exactResumePlan(argv: nil))
    }

    func testSubscriptionsAddWorkspaceReorderedOnProtocol19() {
        XCTAssertEqual(
            HerdrClient.subscriptions(forProtocol: 19),
            HerdrClient.defaultSubscriptions + ["workspace.reordered"]
        )
        XCTAssertEqual(
            HerdrClient.subscriptions(forProtocol: 20),
            HerdrClient.defaultSubscriptions + ["workspace.reordered"]
        )
    }

    func testSubscriptionsStayBaselineForOldOrUnknownProtocol() {
        // Pre-19 servers reject unknown subscription types with
        // invalid_request, which would kill the whole event stream.
        XCTAssertEqual(
            HerdrClient.subscriptions(forProtocol: 17),
            HerdrClient.defaultSubscriptions
        )
        XCTAssertEqual(
            HerdrClient.subscriptions(forProtocol: nil),
            HerdrClient.defaultSubscriptions
        )
    }

    private func decode(_ json: String) throws -> SessionSnapshot {
        try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
    }
}
