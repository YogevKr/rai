import Foundation
import XCTest

@testable import RaiCore

final class AgentStatuslineTests: XCTestCase {
    func testClaudeFixturesProvideModelEffortAndDirectory() throws {
        let names = [
            "ask-user-question-q1",
            "ask-user-question-q2-multiselect",
            "ask-user-question-submit",
            "trust-dialog",
        ]
        for name in names {
            let status = try XCTUnwrap(AgentStatuslineParser.parse(fixture(name)), name)

            XCTAssertEqual(status.model, "Fable 5.1", name)
            XCTAssertEqual(status.effort, "xhigh", name)
            XCTAssertEqual(status.cwd, "/private/tmp/rai-herdr-lab-9edc55ff/work", name)
        }
    }

    func testClaudeBottomRowsProvideModeAgentsAndShortDirectory() throws {
        let grid = """
        output
        ⏸ manual mode on · ? for shortcuts · ← 3 agents
        ◉ xhigh · /effort
        /rc
        """
        let status = try XCTUnwrap(AgentStatuslineParser.parse(grid))

        XCTAssertEqual(status.mode, "manual")
        XCTAssertEqual(status.effort, "xhigh")
        XCTAssertEqual(status.agentCount, 3)
        XCTAssertEqual(status.cwd, "/rc")
    }

    func testCodexCaptureProvidesModelEffortAndDirectory() throws {
        let status = try XCTUnwrap(AgentStatuslineParser.parse(fixture("codex-statusline")))

        XCTAssertEqual(status.model, "gpt-5.6-sol")
        XCTAssertEqual(status.effort, "high")
        XCTAssertEqual(status.cwd, "~")
    }

    func testBranchSegmentIsOptional() throws {
        let status = try XCTUnwrap(AgentStatuslineParser.parse(
            "gpt-5.6-sol · high · ~/rai · branch: codexspin/qol"
        ))
        XCTAssertEqual(status.branch, "codexspin/qol")
    }

    func testOldOutputOutsideBottomRowsDoesNotBecomeStatus() {
        let oldOutput = "gpt-5.6-sol · high · ~/old"
        let blankRows = Array(repeating: "", count: 13).joined(separator: "\n")

        XCTAssertNil(AgentStatuslineParser.parse("\(oldOutput)\n\(blankRows)"))
    }

    func testNormalShellTextDoesNotBecomeAnEffortStatus() {
        XCTAssertNil(AgentStatuslineParser.parse("build risk is high"))
    }

    func testCodexUltraEffortIsSupported() throws {
        let status = try XCTUnwrap(AgentStatuslineParser.parse("gpt-5.6-sol · ultra · ~/rai"))

        XCTAssertEqual(status.effort, "ultra")
    }

    func testDirectoriesKeepSpaces() throws {
        let claude = try XCTUnwrap(AgentStatuslineParser.parse("""
        Claude Code v2.1.259
        Fable 5.1 with xhigh effort
        /Users/me/My Project
        """))
        let codex = try XCTUnwrap(AgentStatuslineParser.parse(
            "gpt-5.6-sol · high · /Users/me/My Project"
        ))

        XCTAssertEqual(claude.cwd, "/Users/me/My Project")
        XCTAssertEqual(codex.cwd, "/Users/me/My Project")
    }

    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/claude-dialogs/\(name).txt")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
