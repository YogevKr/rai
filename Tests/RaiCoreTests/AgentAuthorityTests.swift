@testable import RaiCore
import XCTest

final class AgentAuthorityTests: XCTestCase {
    func testReportArgumentsUseRaiSourceAndCanonicalValues() {
        XCTAssertEqual(
            AgentAuthorityCLI.reportArguments(
                paneID: "w1:p2",
                agent: .antigravity,
                state: .blocked
            ),
            [
                "pane", "report-agent", "w1:p2",
                "--source", "rai:user",
                "--agent", "agy",
                "--state", "blocked",
            ]
        )
    }

    func testDoneMapsToIdleBecauseReportAgentDoesNotAcceptDone() {
        XCTAssertEqual(AgentAuthorityState(status: .done), .idle)
    }

    func testReleaseArgumentsRejectAnEmptyAgent() {
        XCTAssertNil(AgentAuthorityCLI.releaseArguments(paneID: "w1:p2", agent: " \n "))
        XCTAssertEqual(
            AgentAuthorityCLI.releaseArguments(paneID: "w1:p2", agent: " claude "),
            [
                "pane", "release-agent", "w1:p2",
                "--source", "rai:user",
                "--agent", "claude",
            ]
        )
    }

    func testDetectionSummaryUsesKnownDisplayNameAndStatus() {
        XCTAssertEqual(
            AgentAuthorityCLI.detectionSummary(agent: "opencode", status: .working),
            "Herdr detects: OpenCode — Working"
        )
        XCTAssertEqual(
            AgentAuthorityCLI.detectionSummary(agent: nil, status: .unknown),
            "Herdr detects: No agent — Unknown"
        )
    }

    func testPaneContextParsesSessionOwner() throws {
        let context = try XCTUnwrap(
            AgentAuthorityContextParser.parse(
                """
                {
                  "result": {
                    "pane": {
                      "pane_id": "w1:p2",
                      "agent": "claude",
                      "agent_status": "working",
                      "agent_session": {"source": "herdr:claude"}
                    }
                  }
                }
                """
            )
        )
        XCTAssertEqual(
            context,
            AgentAuthorityContext(
                paneID: "w1:p2",
                agent: "claude",
                status: .working,
                sessionSource: "herdr:claude"
            )
        )
        XCTAssertEqual(
            context.reportAvailability,
            .ownedSession(source: "herdr:claude")
        )
    }

    func testReportAvailabilityLetsHerdrArbitrateAgentLabelChanges() {
        let context = AgentAuthorityContext(
            paneID: "w1:p2",
            agent: "codex",
            status: .idle,
            sessionSource: nil
        )
        XCTAssertEqual(context.reportAvailability, .available)
    }

    func testReportAvailabilityAllowsAnUnclaimedPane() {
        let context = AgentAuthorityContext(
            paneID: "w1:p2",
            agent: nil,
            status: .unknown,
            sessionSource: nil
        )
        XCTAssertEqual(context.reportAvailability, .available)
    }

    func testClearRequestTargetsOnlyTheRaiAuthoritySource() throws {
        let data = try AgentAuthorityRPC.clearRequestData(id: "test", paneID: "w1:p2")
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(root["id"] as? String, "test")
        XCTAssertEqual(root["method"] as? String, "pane.clear_agent_authority")
        let params = try XCTUnwrap(root["params"] as? [String: Any])
        XCTAssertEqual(params["pane_id"] as? String, "w1:p2")
        XCTAssertEqual(params["source"] as? String, "rai:user")
    }

    func testClearResponseValidationRejectsRemoteErrors() throws {
        let data = Data(
            #"{"id":"test","error":{"code":"pane_not_found","message":"missing"}}"#.utf8
        )
        XCTAssertThrowsError(try AgentAuthorityRPC.validateResponse(data, id: "test")) {
            guard case AgentAuthorityRPCError.remote(let code, let message) = $0 else {
                return XCTFail("Expected a remote error")
            }
            XCTAssertEqual(code, "pane_not_found")
            XCTAssertEqual(message, "missing")
        }
    }
}
