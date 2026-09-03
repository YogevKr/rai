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

    func testOfflineCacheKeepsPairingAndHerdSession() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rai-history-cache-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: fileURL) }
        let store = TranscriptHistoryCacheStore(fileURL: fileURL)
        store.save(
            pages: ["p1": page(turns: [turn(1, .user, "cached")], hasMore: false)],
            pairingID: "pairing-1",
            sessionName: "herd-1"
        )

        let cached = store.load(pairingID: "pairing-1")
        XCTAssertEqual(cached?.sessionName, "herd-1")
        XCTAssertEqual(cached?.pages["p1"]?.turns.first?.text, "cached")
        XCTAssertNil(store.load(pairingID: "pairing-2"))
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

    private func turn(
        _ index: Int,
        _ role: TranscriptRole,
        _ text: String
    ) -> TranscriptTurn {
        TranscriptTurn(index: index, role: role, text: text)
    }
}
