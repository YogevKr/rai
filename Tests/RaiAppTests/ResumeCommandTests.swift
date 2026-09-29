import XCTest
import RaiCore

@testable import RaiApp

/// Reopening a closed tab must bring the agent back with the flags it was
/// running with — not a bare default invocation.
@MainActor
final class ResumeCommandTests: XCTestCase {
    func testClaudeWithoutArgvUsesDefault() {
        XCTAssertEqual(
            RaiModel.resumeCommand(kind: .claude, argv: nil),
            "claude --continue || claude"
        )
    }

    func testClaudeKeepsFlagsAndAddsContinue() {
        XCTAssertEqual(
            RaiModel.resumeCommand(
                kind: .claude,
                argv: ["claude", "--dangerously-skip-permissions", "--model", "opus"]
            ),
            "claude --dangerously-skip-permissions --model opus --continue"
                + " || claude --dangerously-skip-permissions --model opus"
        )
    }

    func testClaudeDoesNotDuplicateResumeFlag() {
        XCTAssertEqual(
            RaiModel.resumeCommand(kind: .claude, argv: ["claude", "--continue"]),
            "claude --continue"
        )
    }

    func testUnrecognizedBinaryFallsBackToDefault() {
        XCTAssertEqual(
            RaiModel.resumeCommand(kind: .claude, argv: ["/bin/zsh", "-l"]),
            "claude --continue || claude"
        )
    }

    func testCodexKeepsFlags() {
        XCTAssertEqual(
            RaiModel.resumeCommand(kind: .codex, argv: ["codex", "--full-auto"]),
            "codex --full-auto resume --last || codex --full-auto"
        )
    }

    func testFallbackLaunchKeepsCodexScrollback() {
        XCTAssertEqual(RaiModel.agentLaunchCommand(kind: .codex), "codex")
        XCTAssertEqual(RaiModel.agentLaunchCommand(kind: .claude), "claude")
        XCTAssertEqual(RaiModel.agentLaunchCommand(kind: .muse), "muse")
    }

    func testCodexDefaultAndExactResumeKeepScrollback() throws {
        XCTAssertEqual(
            RaiModel.resumeCommand(kind: .codex, argv: nil),
            "codex resume --last || codex"
        )
        let session = try JSONDecoder().decode(AgentSession.self, from: Data(
            #"{"agent":"codex","kind":"id","source":"herdr:codex","value":"session-123"}"#.utf8
        ))
        XCTAssertEqual(
            RaiModel.resumeCommand(kind: .codex, argv: ["codex"], agentSession: session),
            "codex resume session-123 || codex"
        )
    }
}
