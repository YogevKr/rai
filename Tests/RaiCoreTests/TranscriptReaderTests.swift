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

    func testClaudeProjectDirectoryEncodingMatchesLabProbe() {
        XCTAssertEqual(
            ClaudeTranscriptLocator.projectDirectoryName(
                for: "/private/tmp/rai.transcript_history fixture"
            ),
            "-private-tmp-rai-transcript-history-fixture"
        )
    }

    func testNewestRecentTranscriptWins() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rai-transcript-locator-\(UUID().uuidString)")
        let claude = root.appendingPathComponent(".claude")
        let project = claude.appendingPathComponent("projects/-tmp-repo")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 10_000)
        let old = project.appendingPathComponent("old.jsonl")
        let newest = project.appendingPathComponent("new.jsonl")
        try transcript(cwd: "/tmp/repo", sessionID: "old").write(to: old)
        try transcript(cwd: "/tmp/repo", sessionID: "new").write(to: newest)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-100)],
            ofItemAtPath: old.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-10)],
            ofItemAtPath: newest.path
        )

        XCTAssertEqual(
            canonicalPath(ClaudeTranscriptLocator.newestTranscript(
                cwd: "/tmp/repo",
                claudeDirectory: claude,
                now: now,
                maximumAge: 60
            )),
            canonicalPath(newest)
        )
    }

    func testResolutionPrefersBeaconAndFallsBackToNewest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rai-transcript-resolve-\(UUID().uuidString)")
        let claude = root.appendingPathComponent(".claude")
        let project = claude.appendingPathComponent("projects/-tmp-repo")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let beacon = project.appendingPathComponent("beacon.jsonl")
        let newest = project.appendingPathComponent("newest.jsonl")
        try transcript(cwd: "/tmp/repo", sessionID: "beacon").write(to: beacon)
        try transcript(cwd: "/tmp/repo", sessionID: "newest").write(to: newest)
        let now = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-20)],
            ofItemAtPath: beacon.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-10)],
            ofItemAtPath: newest.path
        )

        XCTAssertEqual(
            canonicalPath(ClaudeTranscriptLocator.resolve(
                beaconPath: beacon.path,
                cwd: "/tmp/repo",
                claudeDirectory: claude,
                now: now
            )),
            canonicalPath(beacon)
        )
        XCTAssertEqual(
            canonicalPath(ClaudeTranscriptLocator.resolve(
                beaconPath: root.appendingPathComponent("outside.jsonl").path,
                cwd: "/tmp/repo",
                claudeDirectory: claude,
                now: now
            )),
            canonicalPath(newest)
        )
        XCTAssertEqual(
            canonicalPath(ClaudeTranscriptLocator.resolve(
                beaconPath: nil,
                cwd: "/tmp/repo",
                claudeDirectory: claude,
                sessionID: "beacon",
                now: now
            )),
            canonicalPath(beacon)
        )
        XCTAssertNil(ClaudeTranscriptLocator.resolve(
            beaconPath: nil,
            cwd: "/tmp/repo",
            claudeDirectory: claude,
            sessionID: "missing",
            now: now
        ))
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

    func testFallbackIsAmbiguousForSharedCWDOrMultipleLiveTranscripts() async throws {
        let setup = try transcriptDirectory(cwd: "/tmp/shared")
        addTeardownBlock { try? FileManager.default.removeItem(at: setup.root) }
        try transcript(cwd: "/tmp/shared", sessionID: "one").write(
            to: setup.project.appendingPathComponent("one.jsonl")
        )
        let index = ClaudeTranscriptIndex(claudeDirectory: setup.claude)

        if case .ambiguous = await index.read(
            paneID: "p1", beaconPath: nil, cwd: "/tmp/shared",
            sessionID: nil, fallbackPaneCount: 2
        ) {} else { XCTFail("A shared cwd must be ambiguous") }

        try transcript(cwd: "/tmp/shared", sessionID: "two").write(
            to: setup.project.appendingPathComponent("two.jsonl")
        )
        if case .ambiguous = await index.read(
            paneID: "p1", beaconPath: nil, cwd: "/tmp/shared",
            sessionID: nil, fallbackPaneCount: 1
        ) {} else { XCTFail("Multiple live transcripts must be ambiguous") }

        let ownershipIndex = ClaudeTranscriptIndex(claudeDirectory: setup.claude)
        if case .ambiguous = await ownershipIndex.read(
            paneID: "p1", beaconPath: nil, cwd: "/tmp/shared",
            sessionID: "one", fallbackPaneCount: 2
        ) {} else { XCTFail("A session filename does not make shared cwd fallback safe") }
        let beaconPath = setup.project.appendingPathComponent("one.jsonl").path
        if case .found = await ownershipIndex.read(
            paneID: "p1", beaconPath: beaconPath, cwd: "/tmp/shared",
            sessionID: "one", fallbackPaneCount: 2
        ) {} else { XCTFail("The beacon path should resolve for its first pane") }
        if case .ambiguous = await ownershipIndex.read(
            paneID: "p2", beaconPath: beaconPath, cwd: "/tmp/shared",
            sessionID: "one", fallbackPaneCount: 2
        ) {} else { XCTFail("One transcript must not bind to two panes") }
    }

    func testProjectPrefilterUsesExactTranscriptCWDToAvoidPunctuationCollision() throws {
        let setup = try transcriptDirectory(cwd: "/repo/a-b")
        addTeardownBlock { try? FileManager.default.removeItem(at: setup.root) }
        let dash = setup.project.appendingPathComponent("dash.jsonl")
        let underscore = setup.project.appendingPathComponent("underscore.jsonl")
        try transcript(cwd: "/repo/a-b", sessionID: "dash").write(to: dash)
        try transcript(cwd: "/repo/a_b", sessionID: "underscore").write(to: underscore)

        XCTAssertEqual(canonicalPath(ClaudeTranscriptLocator.newestTranscript(
            cwd: "/repo/a-b", claudeDirectory: setup.claude
        )), canonicalPath(dash))
        XCTAssertEqual(canonicalPath(ClaudeTranscriptLocator.newestTranscript(
            cwd: "/repo/a_b", claudeDirectory: setup.claude
        )), canonicalPath(underscore))
    }

    func testProjectDirectorySymlinkCannotEscapeClaudeProjectsRoot() throws {
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
        try FileManager.default.createSymbolicLink(
            at: projects.appendingPathComponent("-tmp-escape"),
            withDestinationURL: outside
        )

        XCTAssertNil(ClaudeTranscriptLocator.newestTranscript(
            cwd: "/tmp/escape", claudeDirectory: claude
        ))
    }

    func testTranscriptIndexCachesMetadataUntilFileChanges() async throws {
        let setup = try transcriptDirectory(cwd: "/tmp/indexed")
        addTeardownBlock { try? FileManager.default.removeItem(at: setup.root) }
        let file = setup.project.appendingPathComponent("session.jsonl")
        try transcript(cwd: "/tmp/indexed", sessionID: "session").write(to: file)
        let index = ClaudeTranscriptIndex(claudeDirectory: setup.claude)

        _ = await index.read(
            paneID: "p1", beaconPath: nil, cwd: "/tmp/indexed",
            sessionID: nil, fallbackPaneCount: 1
        )
        _ = await index.read(
            paneID: "p1", beaconPath: nil, cwd: "/tmp/indexed",
            sessionID: nil, fallbackPaneCount: 1
        )
        let initialCount = await index.metadataParseCountForTesting()
        XCTAssertEqual(initialCount, 1)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()
        _ = await index.read(
            paneID: "p1", beaconPath: nil, cwd: "/tmp/indexed",
            sessionID: nil, fallbackPaneCount: 1
        )
        let changedCount = await index.metadataParseCountForTesting()
        XCTAssertEqual(changedCount, 2)
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

    private func transcriptDirectory(
        cwd: String
    ) throws -> (root: URL, claude: URL, project: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rai-transcript-test-\(UUID().uuidString)")
        let claude = root.appendingPathComponent(".claude")
        let project = claude.appendingPathComponent("projects")
            .appendingPathComponent(ClaudeTranscriptLocator.projectDirectoryName(for: cwd))
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return (root, claude, project)
    }
}
