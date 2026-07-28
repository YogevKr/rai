import RaiCore
import XCTest

final class TranscriptWorkParserTests: XCTestCase {
    // Fixture lines mirror real Claude Code transcript shapes (synthetic ids).
    private func toolUse(_ name: String, id: String, input: String) -> Substring {
        Substring(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":""# + id
            + #"","name":""# + name + #"","input":"# + input + "}]}}")
    }
    private func toolResult(id: String, text: String) -> Substring {
        Substring(#"{"type":"user","message":{"content":[{"tool_use_id":""# + id
            + #"","type":"tool_result","content":[{"type":"text","text":""# + text + #""}]}]}}"#)
    }
    private func notification(toolUseID: String) -> Substring {
        Substring(#"{"type":"user","message":{"content":"<task-notification>\n<task-id>btask1</task-id>\n<tool-use-id>"#
            + toolUseID + #"</tool-use-id>\n<status>completed</status>"}}"#)
    }

    func testBackgroundAgentPendingUntilNotified() {
        var lines: [Substring] = [
            toolUse("Agent", id: "toolu_A1",
                    input: #"{"description":"Audit iOS app","subagent_type":"general-purpose"}"#),
            toolResult(id: "toolu_A1", text: "Async agent launched successfully. agentId: fff000"),
        ]
        var pending = TranscriptWorkParser.pendingAsyncWork(jsonlLines: lines)
        XCTAssertEqual(pending.map(\.kind), [.subagent])
        XCTAssertEqual(pending.first?.description, "Audit iOS app")

        lines.append(notification(toolUseID: "toolu_A1"))
        pending = TranscriptWorkParser.pendingAsyncWork(jsonlLines: lines)
        XCTAssertTrue(pending.isEmpty)
    }

    func testSynchronousAgentNeverPending() {
        let lines: [Substring] = [
            toolUse("Agent", id: "toolu_S1", input: #"{"description":"Quick check"}"#),
            toolResult(id: "toolu_S1", text: "Here is the full result of my exploration..."),
        ]
        XCTAssertTrue(TranscriptWorkParser.pendingAsyncWork(jsonlLines: lines).isEmpty)
    }

    func testWorkflowPendingUntilNotified() {
        var lines: [Substring] = [
            toolUse("Workflow", id: "toolu_W1", input: #"{"name":"find-flaky-tests"}"#),
            toolResult(id: "toolu_W1", text: "Workflow started with task ID: btask9"),
        ]
        var pending = TranscriptWorkParser.pendingAsyncWork(jsonlLines: lines)
        XCTAssertEqual(pending.map(\.kind), [.workflow])
        XCTAssertEqual(pending.first?.description, "find-flaky-tests")

        lines.append(notification(toolUseID: "toolu_W1"))
        pending = TranscriptWorkParser.pendingAsyncWork(jsonlLines: lines)
        XCTAssertTrue(pending.isEmpty)
    }

    func testBackgroundBashAndForegroundBashDistinguished() {
        let lines: [Substring] = [
            toolUse("Bash", id: "toolu_B1",
                    input: #"{"command":"sleep 600","run_in_background":true,"description":"Long wait"}"#),
            toolResult(id: "toolu_B1", text: "Command running in background with ID: bxyz"),
            toolUse("Bash", id: "toolu_B2", input: #"{"command":"ls","description":"List"}"#),
            toolResult(id: "toolu_B2", text: "file1 file2"),
        ]
        let pending = TranscriptWorkParser.pendingAsyncWork(jsonlLines: lines)
        XCTAssertEqual(pending.map(\.toolUseID), ["toolu_B1"])
        XCTAssertEqual(pending.first?.description, "Long wait")
    }

    func testStoppedNotificationAlsoCompletes() {
        let lines: [Substring] = [
            toolUse("Monitor", id: "toolu_M1", input: #"{"command":"until x; do sleep 2; done","description":"Wait for x"}"#),
            toolResult(id: "toolu_M1", text: "Monitor registered."),
            Substring(#"{"content":"<task-notification><tool-use-id>toolu_M1</tool-use-id><status>stopped</status>"}"#),
        ]
        XCTAssertTrue(TranscriptWorkParser.pendingAsyncWork(jsonlLines: lines).isEmpty)
    }

    func testUnparseableLinesSkipped() {
        let lines: [Substring] = ["not json at all", "{\"broken\": ", ""]
        XCTAssertTrue(TranscriptWorkParser.pendingAsyncWork(jsonlLines: lines).isEmpty)
    }
}
