import XCTest

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
}
