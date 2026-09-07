import RaiCore
import XCTest
@testable import RaiApp

final class AgentLaunchReadinessTests: XCTestCase {
    private func context(
        paneID: String = "w1:p1",
        agent: String? = "claude",
        status: AgentStatus = .blocked
    ) -> AgentAuthorityContext {
        AgentAuthorityContext(paneID: paneID, agent: agent, status: status, sessionSource: nil)
    }

    @MainActor
    private func waiting(_ output: String, context: AgentAuthorityContext?) -> Bool {
        RaiModel.isWaitingForLaunchInput(
            output: output, paneID: "w1:p1", kind: .claude, context: context
        )
    }

    @MainActor
    func testTrustPromptIsALaunchedAgentWaitingForInput() {
        // Herdr returns a nonzero exit status even though Claude's trust
        // prompt is visible and its pane reports a blocked Claude process.
        let response = #"{"id":"cli:agent:start","error":{"code":"agent_not_ready","message":"agent claude-123 is blocked during startup and is not ready for prompts"}}"#
        XCTAssertTrue(waiting(response, context: context()))
    }

    @MainActor
    func testStartupTimeoutCanRecoverOnlyWithALiveBlockedAgent() {
        let response = #"{"id":"cli:agent:start","error":{"code":"timeout","message":"timed out waiting for agent startup"}}"#
        XCTAssertTrue(waiting(response, context: context()))
        XCTAssertFalse(waiting(response, context: nil))
        XCTAssertFalse(waiting(response, context: context(agent: nil)))
        for status in [AgentStatus.idle, .done, .working, .unknown] {
            XCTAssertFalse(waiting(response, context: context(status: status)))
        }
    }

    @MainActor
    func testOtherPaneOrAgentCannotSatisfyTheLaunch() {
        let response = #"{"error":{"code":"agent_not_ready"}}"#
        XCTAssertFalse(waiting(response, context: context(paneID: "w2:p1")))
        XCTAssertFalse(waiting(response, context: context(agent: "codex")))
        XCTAssertFalse(waiting(response, context: nil))
    }

    @MainActor
    func testRealLaunchErrorsRemainFailuresEvenWithABlockedPane() {
        for code in ["agent_start_failed", "agent_start_input_failed", "agent_kind_mismatch",
                     "agent_name_lost", "agent_pane_busy", "agent_start_transport_failed"] {
            let response = "{\"error\":{\"code\":\"\(code)\"}}"
            XCTAssertFalse(waiting(response, context: context()), code)
        }
        XCTAssertFalse(waiting("agent_not_ready", context: context()))
        XCTAssertFalse(waiting(#"{"result":{"message":"agent_not_ready"}}"#, context: context()))
    }

    @MainActor
    func testCodexStartupPromptUsesTheSameRule() {
        XCTAssertTrue(RaiModel.isWaitingForLaunchInput(
            output: #"{"error":{"code":"agent_not_ready"}}"#,
            paneID: "w1:p1", kind: .codex, context: context(agent: "codex")
        ))
    }
}
