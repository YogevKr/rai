import RaiCore
import XCTest

@testable import rai

@MainActor
final class TranscriptHistoryViewModelTests: XCTestCase {
    func testFilterMatchesTextToolNameAndSummary() {
        let model = TranscriptHistoryViewModel(page: page(
            turns: [
                turn(0, .user, "Fix the bridge"),
                TranscriptTurn(
                    index: 1,
                    role: .assistant,
                    text: "",
                    tool: TranscriptTool(name: "Bash", summary: "swift test")
                ),
                turn(2, .assistant, "All checks pass"),
            ],
            hasMore: false
        ))

        model.query = "BRIDGE"
        XCTAssertEqual(model.filteredTurns.map(\.index), [0])
        model.query = "bash"
        XCTAssertEqual(model.filteredTurns.map(\.index), [1])
        model.query = "swift"
        XCTAssertEqual(model.filteredTurns.map(\.index), [1])
    }

    func testSearchRangesRebuildOnlyWhenQueryOrHistoryChanges() {
        let model = TranscriptHistoryViewModel(page: page(
            turns: [turn(0, .assistant, "Pass then pass again")],
            hasMore: false
        ))
        let initialBuilds = model.searchCacheBuildCount

        model.query = "pass"
        let queryBuilds = model.searchCacheBuildCount
        XCTAssertEqual(queryBuilds, initialBuilds + 1)
        XCTAssertEqual(model.matchRanges(for: 0)?.text.count, 2)

        _ = model.filteredTurns
        _ = model.filteredTurns
        XCTAssertEqual(model.searchCacheBuildCount, queryBuilds)

        model.apply(page(
            turns: [turn(1, .assistant, "another pass")],
            hasMore: false
        ))
        XCTAssertEqual(model.searchCacheBuildCount, queryBuilds + 1)
        XCTAssertEqual(model.filteredTurns.map(\.index), [1])
    }

    func testLoadOlderMergesInOrderAndMovesBeforeIndex() {
        let model = TranscriptHistoryViewModel(page: page(
            turns: [turn(4, .user, "new prompt"), turn(5, .assistant, "new reply")],
            hasMore: true
        ))
        XCTAssertEqual(model.olderBeforeTurnIndex, 4)

        model.apply(page(
            turns: [turn(2, .user, "old prompt"), turn(3, .assistant, "old reply")],
            hasMore: false
        ))

        XCTAssertEqual(model.turns.map(\.index), [2, 3, 4, 5])
        XCTAssertNil(model.olderBeforeTurnIndex)
        XCTAssertEqual(model.lastPromptIndex, 4)
    }

    func testNewSessionDropsOldTurns() {
        let model = TranscriptHistoryViewModel(page: page(
            turns: [turn(8, .assistant, "old")],
            hasMore: false
        ))
        model.apply(TranscriptHistoryPage(
            paneID: "p1",
            sessionID: "session-2",
            turns: [turn(0, .user, "new")],
            hasMore: false,
            sinceLastSeen: nil
        ))

        XCTAssertEqual(model.turns.map(\.text), ["new"])
        XCTAssertEqual(model.sessionID, "session-2")
        XCTAssertNil(model.sinceLastSeen)
    }

    func testClearRemovesPriorHerdTurns() {
        let model = TranscriptHistoryViewModel(page: page(
            turns: [turn(8, .assistant, "old herd")],
            hasMore: true
        ))

        model.clear()

        XCTAssertTrue(model.turns.isEmpty)
        XCTAssertTrue(model.sessionID.isEmpty)
        XCTAssertFalse(model.hasMore)
        XCTAssertNil(model.sinceLastSeen)
    }

    func testNewInitialPageReplacesAwayMarker() {
        let model = TranscriptHistoryViewModel(page: page(
            turns: [turn(4, .assistant, "old")],
            hasMore: false
        ))
        model.apply(TranscriptHistoryPage(
            paneID: "p1",
            sessionID: "session-1",
            turns: [turn(4, .assistant, "old"), turn(5, .assistant, "new")],
            hasMore: false,
            sinceLastSeen: 4
        ))

        XCTAssertEqual(model.sinceLastSeen, 4)
    }

    func testOfflineCacheKeepsPairingAndHerdSession() async {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rai-history-cache-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: fileURL) }
        let store = TranscriptHistoryCacheStore(fileURL: fileURL)
        await store.save(
            pages: ["p1": page(turns: [turn(1, .user, "cached")], hasMore: false)],
            pairingID: "pairing-1",
            sessionName: "herd-1"
        )

        let cached = await store.load(pairingID: "pairing-1")
        XCTAssertEqual(cached?.sessionName, "herd-1")
        XCTAssertEqual(cached?.pages["p1"]?.turns.first?.text, "cached")
        let other = await store.load(pairingID: "pairing-2")
        XCTAssertNil(other)
    }

    func testOfflineCacheRejectsAnotherLiveHerd() {
        let cached = CachedTranscriptHistories(
            pages: [:], pairingID: "pairing", sessionName: "herd-a"
        )

        XCTAssertTrue(cached.belongs(to: "pairing", currentSessionName: nil))
        XCTAssertTrue(cached.belongs(to: "pairing", currentSessionName: "herd-a"))
        XCTAssertFalse(cached.belongs(to: "pairing", currentSessionName: "herd-b"))
    }

    func testStaleHistoryReplyTripleIsRejectedAfterSessionChange() {
        let request = PendingHistoryRequest(
            generation: 1,
            replacesPage: true,
            sessionName: "herd",
            paneID: "p1",
            sessionID: "new-session",
            requestID: "new-request"
        )
        let stale = TranscriptHistoryPage(
            paneID: "p1",
            sessionID: "old-session",
            resolvedSessionID: "old-session",
            requestID: "old-request",
            turns: [],
            hasMore: false
        )

        XCTAssertFalse(request.matches(stale))
        XCTAssertTrue(PendingHistoryRequest.sessionChanged(
            previous: "old-session", current: "new-session"
        ))
        XCTAssertTrue(PendingHistoryRequest.sessionChanged(
            previous: "", current: "new-session"
        ))
    }

    func testCacheRestoreUsesLiveBeaconAndMarksUnknownSession() throws {
        let connection = BridgeConnection()
        connection.replaceWithLiveSnapshot(try snapshot(
            sessionID: "session-2", beaconSessionID: "session-2"
        ))
        connection.restoreCachedHistory(
            [
                "p1": page(turns: [turn(1, .assistant, "old")], hasMore: false),
                "untagged": TranscriptHistoryPage(
                    paneID: "untagged", sessionID: "", turns: [], hasMore: false
                ),
            ],
            sessionName: "herd"
        )

        XCTAssertNil(connection.historyPages["p1"])
        XCTAssertNil(connection.historyPages["untagged"])

        let pendingBeacon = BridgeConnection()
        pendingBeacon.replaceWithLiveSnapshot(try snapshot(sessionID: "session-1"))
        pendingBeacon.restoreCachedHistory(
            ["p1": page(turns: [turn(1, .assistant, "old")], hasMore: false)],
            sessionName: "herd"
        )
        XCTAssertNotNil(pendingBeacon.historyPages["p1"])
        XCTAssertTrue(pendingBeacon.historyFromPreviousSession.contains("p1"))

        pendingBeacon.replaceWithLiveSnapshot(try snapshot(
            sessionID: "session-2", beaconSessionID: "session-2"
        ))

        XCTAssertNil(pendingBeacon.historyPages["p1"])
        XCTAssertFalse(pendingBeacon.historyFromPreviousSession.contains("p1"))
    }

    func testHistoryRetentionEvictsClosedAndLeastRecentlyUsedPanes() {
        let now = Date(timeIntervalSince1970: 1_000)
        let pages = Dictionary(uniqueKeysWithValues: (0..<10).map { index in
            ("p\(index)", TranscriptHistoryPage(
                paneID: "p\(index)",
                sessionID: "s\(index)",
                turns: [turn(index, .assistant, "turn")],
                hasMore: false
            ))
        })
        let access = Dictionary(uniqueKeysWithValues: (0..<10).map {
            ("p\($0)", now.addingTimeInterval(TimeInterval($0)))
        })
        let evictions = TranscriptHistoryRetentionPolicy.evictions(
            pages: pages,
            lastAccess: access,
            missingSince: ["p9": now.addingTimeInterval(-31)],
            now: now
        )

        XCTAssertTrue(evictions.contains("p9"))
        XCTAssertTrue(evictions.contains("p0"))
        XCTAssertEqual(pages.count - evictions.count, 8)

        let twoPageBudget = TranscriptHistoryRetentionPolicy.estimatedBytes(pages["p8"])
            + TranscriptHistoryRetentionPolicy.estimatedBytes(pages["p7"])
        let byteEvictions = TranscriptHistoryRetentionPolicy.evictions(
            pages: pages,
            lastAccess: access,
            missingSince: [:],
            now: now,
            maximumPanes: 10,
            maximumBytes: twoPageBudget,
            closedPaneGrace: 30
        )
        XCTAssertEqual(pages.count - byteEvictions.count, 2)
    }

    func testClosedPaneWithoutPageEntersRetentionSet() throws {
        let connection = BridgeConnection()
        let now = Date(timeIntervalSince1970: 1_000)
        connection.replaceWithLiveSnapshot(
            try snapshot(sessionID: "session-1", beaconSessionID: "session-1"),
            receivedAt: now
        )
        XCTAssertNil(connection.historyPages["p1"])
        XCTAssertTrue(connection.trackedHistoryPaneIDs.contains("p1"))

        connection.replaceWithLiveSnapshot(
            try emptySnapshot(),
            receivedAt: now
        )
        connection.pruneHistory(now: now.addingTimeInterval(31))

        XCTAssertFalse(connection.trackedHistoryPaneIDs.contains("p1"))
    }

    func testHistoryRetentionTrimsButNeverEvictsActivePane() {
        let active = TranscriptHistoryPage(
            paneID: "active",
            sessionID: "session",
            turns: (0..<4).map { turn($0, .assistant, String(repeating: "x", count: 200)) },
            hasMore: false
        )
        let trimmed = TranscriptHistoryRetentionPolicy.trimmingOldestTurns(
            active,
            maximumBytes: 500
        )
        let other = page(turns: [turn(0, .assistant, "other")], hasMore: false)
        let evictions = TranscriptHistoryRetentionPolicy.evictions(
            pages: ["active": trimmed, "other": other],
            lastAccess: ["other": .distantFuture],
            missingSince: [:],
            now: Date(),
            protectedPaneID: "active",
            maximumPanes: 2,
            maximumBytes: TranscriptHistoryRetentionPolicy.estimatedBytes(trimmed)
        )

        XCTAssertLessThan(trimmed.turns.count, active.turns.count)
        XCTAssertEqual(trimmed.turns.last?.index, active.turns.last?.index)
        XCTAssertTrue(trimmed.hasMore)
        XCTAssertFalse(evictions.contains("active"))
        XCTAssertTrue(evictions.contains("other"))
    }

    func testOfflineCacheDropsUnreadableAndOverCapFiles() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rai-history-bad-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: fileURL) }
        let store = TranscriptHistoryCacheStore(fileURL: fileURL)

        try Data("not json".utf8).write(to: fileURL)
        let unreadable = await store.load(pairingID: "pairing")
        XCTAssertNil(unreadable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        try Data(repeating: 0, count: TranscriptHistoryCacheStore.maximumTotalBytes + 65_000)
            .write(to: fileURL)
        let oversized = await store.load(pairingID: "pairing")
        XCTAssertNil(oversized)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testOfflineCacheBoundsEachPaneAndTotalWriteSize() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rai-history-bounds-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: fileURL) }
        let pages = Dictionary(uniqueKeysWithValues: (0..<9).map { index in
            ("p\(index)", TranscriptHistoryPage(
                paneID: "p\(index)",
                sessionID: "session",
                turns: [turn(index, .assistant, String(repeating: "x", count: 600_000))],
                hasMore: false
            ))
        })
        let bounded = TranscriptHistoryCacheStore.boundedPages(pages)

        XCTAssertEqual(bounded.count, TranscriptHistoryCacheStore.maximumPanes)
        for page in bounded.values {
            XCTAssertLessThanOrEqual(
                try JSONEncoder().encode(page).count,
                TranscriptHistoryCacheStore.maximumPaneBytes
            )
        }
        let store = TranscriptHistoryCacheStore(fileURL: fileURL)
        await store.save(pages: pages, pairingID: "pairing", sessionName: "herd")
        let size = try XCTUnwrap(
            fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )
        XCTAssertLessThanOrEqual(size, TranscriptHistoryCacheStore.maximumTotalBytes)
    }

    func testHistoryErrorMatchesOnlyItsPendingPaneRequest() {
        let request = PendingHistoryRequest(
            generation: 1,
            replacesPage: true,
            sessionName: "herd",
            paneID: "p1",
            sessionID: "session",
            requestID: "request"
        )
        let other = PendingHistoryRequest(
            generation: 1,
            replacesPage: true,
            sessionName: "herd",
            paneID: "p2",
            sessionID: "session-2",
            requestID: "request-2"
        )
        var pending = ["p1": request, "p2": other]

        let routed = TranscriptHistoryErrorRouter.consume(
            pending: &pending,
            paneID: "p1",
            sessionID: "session",
            requestID: "request",
            message: "This pane is closed."
        )
        XCTAssertEqual(routed?.paneID, "p1")
        XCTAssertEqual(routed?.message, "This pane is closed.")
        XCTAssertNil(pending["p1"])
        XCTAssertNotNil(pending["p2"])
    }

    func testAnyLegacyErrorCompletesPendingHistoryRequests() {
        var pending = [
            "p1": PendingHistoryRequest(
                generation: 1, replacesPage: true, sessionName: "herd",
                paneID: "p1", sessionID: "s1", requestID: "r1"
            ),
            "p2": PendingHistoryRequest(
                generation: 1, replacesPage: true, sessionName: "herd",
                paneID: "p2", sessionID: "s2", requestID: "r2"
            ),
        ]

        let errors = TranscriptHistoryErrorRouter.consumeAnyLegacyError(
            pending: &pending,
            message: "Invalid bridge message."
        )

        XCTAssertEqual(Set(errors?.keys.map { $0 } ?? []), Set(["p1", "p2"]))
        XCTAssertTrue(pending.isEmpty)
    }

    private func page(
        turns: [TranscriptTurn],
        hasMore: Bool
    ) -> TranscriptHistoryPage {
        TranscriptHistoryPage(
            paneID: "p1",
            sessionID: "session-1",
            turns: turns,
            hasMore: hasMore,
            sinceLastSeen: 3
        )
    }

    private func snapshot(
        sessionID: String,
        beaconSessionID: String? = nil
    ) throws -> SessionSnapshot {
        let beacon = beaconSessionID.map { sessionID in
            """
            ,"beacon":{"event":"Stop","pane_id":"p1",
              "session_id":"\(sessionID)","cwd":"/repo",
              "transcript_path":"/tmp/\(sessionID).jsonl","ts":1}
            """
        } ?? ""
        let json = """
        {
          "version":"0.7.5","protocol":16,
          "focused_workspace_id":null,"focused_tab_id":null,"focused_pane_id":null,
          "workspaces":[],"tabs":[],
          "panes":[{
            "pane_id":"p1","terminal_id":"term-1","workspace_id":"w1",
            "tab_id":"t1","focused":true,"cwd":"/repo",
            "agent":"claude","agent_status":"working","revision":1,
            "agent_session":{"agent":"claude","kind":"id",
              "source":"herdr:claude","value":"\(sessionID)"}
            \(beacon)
          }],
          "layouts":[]
        }
        """
        return try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
    }

    private func emptySnapshot() throws -> SessionSnapshot {
        let json = """
        {"version":"0.7.5","protocol":16,
         "focused_workspace_id":null,"focused_tab_id":null,"focused_pane_id":null,
         "workspaces":[],"tabs":[],"panes":[],"layouts":[]}
        """
        return try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
    }

    private func turn(
        _ index: Int,
        _ role: TranscriptRole,
        _ text: String
    ) -> TranscriptTurn {
        TranscriptTurn(index: index, role: role, text: text)
    }
}
