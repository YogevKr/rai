import Foundation
import RaiCore
import XCTest

final class TranscriptReaderTests: XCTestCase {
    func testRealClaudeFixtureParsesDisplayTurnsAndSkipsTruncatedTail() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/claude-transcripts/claude-2.1.259.jsonl")
        let document = try TranscriptReader.read(url: url)

        XCTAssertEqual(document.sessionID, "3b4312dc-2ffc-4ac8-a6bb-f87a3659ece3")
        XCTAssertEqual(document.turns.count, 7)
        XCTAssertEqual(
            document.turns.map(\.role),
            [.user, .assistant, .user, .assistant, .assistant, .tool, .assistant]
        )
        XCTAssertEqual(document.turns.map(\.index), document.turns.map(\.index).sorted())
        XCTAssertEqual(Set(document.turns.map(\.index)).count, 7)
        XCTAssertEqual(document.turns[4].tool?.name, "Bash")
        XCTAssertEqual(
            document.turns[4].tool?.summary,
            "printf 'fixture-tool-output\\n'"
        )
        XCTAssertEqual(document.turns[5].text, "fixture-tool-output")
        XCTAssertNotNil(document.turns[0].timestamp)
        XCTAssertTrue(document.skippedRecordTypes.isSuperset(of: [
            "mode", "file-history-snapshot", "system",
        ]))
    }

    func testToolResultIsTruncatedAtItsOwnBound() {
        let result = String(repeating: "x", count: TranscriptReader.maximumToolResultBytes + 20)
        let text = """
        {"type":"user","sessionId":"s1","message":{"role":"user","content":[{"type":"tool_result","content":"\(result)"}]}}
        """
        let turn = TranscriptReader.read(text: text).turns.first

        XCTAssertEqual(turn?.text.utf8.count, TranscriptReader.maximumToolResultBytes)
        XCTAssertEqual(turn?.truncated, true)
    }

    func testToolSummaryReportsTruncation() {
        let command = String(repeating: "x", count: TranscriptReader.maximumToolSummaryBytes + 20)
        let text = """
        {"type":"assistant","sessionId":"s1","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"\(command)"}}]}}
        """
        let turn = TranscriptReader.read(text: text).turns.first

        XCTAssertEqual(turn?.tool?.summary.utf8.count, TranscriptReader.maximumToolSummaryBytes)
        XCTAssertEqual(turn?.truncated, true)
    }

    func testSidechainRecordsStayOutOfConversationHistory() {
        let text = """
        {"type":"user","sessionId":"s1","isSidechain":true,"message":{"role":"user","content":"internal prompt"}}
        {"type":"assistant","sessionId":"s1","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"internal reply"}]}}
        {"type":"user","sessionId":"s1","message":{"role":"user","content":"visible prompt"}}
        """
        let document = TranscriptReader.read(text: text)

        XCTAssertEqual(document.turns.map(\.text), ["visible prompt"])
    }

    func testTranscriptIndexRequiresBeaconPathAndMatchingSession() async throws {
        let setup = try transcriptDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: setup.root) }
        let file = setup.project.appendingPathComponent("session.jsonl")
        try transcript(cwd: "/tmp/repo", sessionID: "session").write(to: file)
        let index = ClaudeTranscriptIndex(claudeDirectory: setup.claude)

        if case .hookRequired = await index.read(
            paneID: "p1", beaconPath: nil, sessionID: "session"
        ) {} else { XCTFail("A session ID without a beacon path must not resolve") }
        let missingHookPage = await index.page(
            paneID: "p1", beaconPath: nil, sessionID: nil,
            requestedSessionID: "", requestID: "missing-hook",
            herdSessionName: "herd", beforeTurnIndex: nil, limit: 50
        )
        XCTAssertEqual(missingHookPage.state, .hookRequired)
        XCTAssertTrue(missingHookPage.turns.isEmpty)
        if case .hookRequired = await index.read(
            paneID: "p1", beaconPath: file.path, sessionID: nil
        ) {} else { XCTFail("A beacon path without its session ID must not resolve") }
        if case .notFound = await index.read(
            paneID: "p1", beaconPath: file.path, sessionID: "other"
        ) {} else { XCTFail("The beacon path and session ID must match") }
        if case let .found(url, document) = await index.read(
            paneID: "p1", beaconPath: file.path, sessionID: "session"
        ) {
            XCTAssertEqual(canonicalPath(url), canonicalPath(file))
            XCTAssertEqual(document.sessionID, "session")
        } else { XCTFail("A complete matching beacon must resolve") }
    }

    func testTranscriptIndexBuildsBoundedPage() async throws {
        let setup = try transcriptDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: setup.root) }
        let file = setup.project.appendingPathComponent("session.jsonl")
        let lines = (0..<80).map { index in
            """
            {"type":"assistant","sessionId":"session","message":{"id":"message-\(index)","role":"assistant","content":[{"type":"text","text":"turn \(index)"}]}}
            """
        }.joined(separator: "\n")
        try Data(lines.utf8).write(to: file)
        let index = ClaudeTranscriptIndex(claudeDirectory: setup.claude)

        let page = await index.page(
            paneID: "p1",
            beaconPath: file.path,
            sessionID: "session",
            requestedSessionID: "session",
            requestID: "request",
            herdSessionName: "herd",
            beforeTurnIndex: nil,
            limit: 500
        )

        XCTAssertEqual(page.turns.count, 50)
        XCTAssertEqual(page.turns.first?.text, "turn 30")
        XCTAssertEqual(page.turns.last?.text, "turn 79")
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.requestID, "request")
        XCTAssertEqual(page.state, .available)
    }

    func testPaneRestartRequiresNewResolution() {
        let old = TranscriptPaneIdentity(
            agent: "claude", sessionID: "first", status: .done
        )
        XCTAssertTrue(TranscriptPaneIdentity(
            agent: "claude", sessionID: "second", status: .working
        ).requiresTranscriptResolution(after: old))
        XCTAssertTrue(TranscriptPaneIdentity(
            agent: "claude", sessionID: "first", status: .working
        ).requiresTranscriptResolution(after: old))
        XCTAssertFalse(TranscriptPaneIdentity(
            agent: "claude", sessionID: "first", status: .done
        ).requiresTranscriptResolution(after: old))
    }

    func testBeaconSymlinkCannotEscapeClaudeProjectsRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rai-transcript-symlink-\(UUID().uuidString)")
        let claude = root.appendingPathComponent(".claude")
        let projects = claude.appendingPathComponent("projects")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try transcript(cwd: "/tmp/escape", sessionID: "escaped").write(
            to: outside.appendingPathComponent("escaped.jsonl")
        )
        let link = projects.appendingPathComponent("escaped.jsonl")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: outside.appendingPathComponent("escaped.jsonl")
        )

        XCTAssertNil(ClaudeTranscriptLocator.beaconTranscript(
            path: link.path, sessionID: "escaped", claudeDirectory: claude
        ))
    }

    func testPaginationClampsLimitAndBoundsText() {
        let turns = (0..<80).map { index in
            TranscriptTurn(
                index: index,
                role: .assistant,
                text: String(repeating: "x", count: 9_000)
            )
        }
        let page = TranscriptPagination.page(
            paneID: "p1",
            sessionID: "s1",
            turns: turns,
            beforeTurnIndex: 70,
            limit: 500
        )

        XCTAssertEqual(page.turns.count, 50)
        XCTAssertEqual(page.turns.first?.index, 20)
        XCTAssertEqual(page.turns.last?.index, 69)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.turns.first?.text.utf8.count, 8_192)
        XCTAssertEqual(page.turns.first?.truncated, true)

        let minimum = TranscriptPagination.page(
            paneID: "p1",
            sessionID: "s1",
            turns: turns,
            beforeTurnIndex: nil,
            limit: 0
        )
        XCTAssertEqual(minimum.turns.count, 1)
        XCTAssertEqual(minimum.turns.first?.index, 79)
    }

    func testSinceLastSeenAppearsOncePerConnectionAndSurvivesReconnect() {
        var tracker = HistoryDeliveryTracker<String, String>()

        XCTAssertNil(tracker.sinceLastSeen(
            device: "phone", connection: "first", paneID: "p1", sessionID: "s1"
        ))
        tracker.recordDelivery(
            device: "phone", connection: "first", paneID: "p1", sessionID: "s1",
            highestTurnIndex: 8
        )
        XCTAssertNil(tracker.sinceLastSeen(
            device: "phone", connection: "first", paneID: "p1", sessionID: "s1"
        ))
        XCTAssertEqual(tracker.sinceLastSeen(
            device: "phone", connection: "second", paneID: "p1", sessionID: "s1"
        ), 8)
        tracker.recordDelivery(
            device: "phone", connection: "second", paneID: "p1", sessionID: "s1",
            highestTurnIndex: 12
        )
        XCTAssertNil(tracker.sinceLastSeen(
            device: "other", connection: "third", paneID: "p1", sessionID: "s1"
        ))
        XCTAssertNil(tracker.sinceLastSeen(
            device: "phone", connection: "fourth", paneID: "p1", sessionID: "s2"
        ))
    }

    func testFailedHistorySendDoesNotAdvanceDelivery() {
        var tracker = HistoryDeliveryTracker<String, String>()
        tracker.recordDelivery(
            device: "phone", connection: "first", paneID: "p1", sessionID: "s1",
            highestTurnIndex: 8
        )
        XCTAssertEqual(tracker.sinceLastSeen(
            device: "phone", connection: "second", paneID: "p1", sessionID: "s1"
        ), 8)
        XCTAssertEqual(tracker.sinceLastSeen(
            device: "phone", connection: "third", paneID: "p1", sessionID: "s1"
        ), 8)
    }

    func testDeliveryCursorsUsePerDeviceLRUAndClearOnRevocation() {
        var tracker = HistoryDeliveryTracker<String, String>(maximumPanesPerDevice: 2)
        for pane in ["p0", "p1"] {
            tracker.recordDelivery(
                device: "phone", connection: "old", paneID: pane,
                sessionID: "session", highestTurnIndex: 1
            )
        }
        XCTAssertEqual(tracker.sinceLastSeen(
            device: "phone", connection: "read", paneID: "p0", sessionID: "session"
        ), 1)
        tracker.recordDelivery(
            device: "phone", connection: "old", paneID: "p2",
            sessionID: "session", highestTurnIndex: 2
        )

        XCTAssertEqual(tracker.cursorCount(for: "phone"), 2)
        XCTAssertNil(tracker.sinceLastSeen(
            device: "phone", connection: "new", paneID: "p1", sessionID: "session"
        ))
        XCTAssertEqual(tracker.sinceLastSeen(
            device: "phone", connection: "new", paneID: "p0", sessionID: "session"
        ), 1)

        tracker.removeDevice("phone")
        XCTAssertEqual(tracker.cursorCount(for: "phone"), 0)
        XCTAssertNil(tracker.sinceLastSeen(
            device: "phone", connection: "after-revoke", paneID: "p0",
            sessionID: "session"
        ))
    }

    func testHistoryReceiptsMustMatchSentPagesAndStayBounded() {
        var ledger = HistoryReceiptLedger<String>()
        let expected = HistoryPageReceipt(
            paneID: "p1", sessionID: "s1", herdSessionName: "herd-1",
            throughTurnIndex: 8
        )
        ledger.recordSent(expected, connection: "first")

        XCTAssertFalse(ledger.acknowledge(
            HistoryPageReceipt(
                paneID: "p1", sessionID: "s1", herdSessionName: "herd-2",
                throughTurnIndex: 8
            ),
            connection: "first"
        ))
        XCTAssertFalse(ledger.acknowledge(
            HistoryPageReceipt(
                paneID: "p1", sessionID: "s1", herdSessionName: "herd-1",
                throughTurnIndex: 9
            ),
            connection: "first"
        ))
        XCTAssertTrue(ledger.acknowledge(expected, connection: "first"))
        XCTAssertFalse(ledger.acknowledge(expected, connection: "first"))

        for index in 0...HistoryReceiptLedger<String>.maximumPendingPerConnection {
            ledger.recordSent(
                HistoryPageReceipt(paneID: "p1", sessionID: "s1", throughTurnIndex: index),
                connection: "second"
            )
        }
        XCTAssertFalse(ledger.acknowledge(
            HistoryPageReceipt(paneID: "p1", sessionID: "s1", throughTurnIndex: 0),
            connection: "second"
        ))
    }

    private func canonicalPath(_ url: URL?) -> String? {
        url?.path.replacingOccurrences(of: "/private/var/", with: "/var/")
    }

    private func transcript(cwd: String, sessionID: String) -> Data {
        Data("""
        {"type":"user","cwd":"\(cwd)","sessionId":"\(sessionID)","message":{"role":"user","content":"hello"}}
        """.utf8)
    }

    private func transcriptDirectory() throws -> (root: URL, claude: URL, project: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rai-transcript-test-\(UUID().uuidString)")
        let claude = root.appendingPathComponent(".claude")
        let project = claude.appendingPathComponent("projects")
            .appendingPathComponent("fixture")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return (root, claude, project)
    }
}
