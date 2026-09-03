import RaiCore
import XCTest

@testable import RaiApp

@MainActor
final class RaiBridgeServerHistoryTests: XCTestCase {
    func testEmptyRequestKeepsBeaconSessionAsReplyIdentity() {
        let base = TranscriptHistoryPage(
            paneID: "pane",
            sessionID: "",
            resolvedSessionID: "beacon-session",
            requestID: "request",
            turns: [],
            hasMore: false
        )

        let reply = RaiBridgeServer.historyPage(
            base,
            requestedSessionID: "",
            requestID: "request",
            sinceLastSeen: nil
        )

        XCTAssertEqual(reply.sessionID, "")
        XCTAssertEqual(reply.resolvedSessionID, "beacon-session")
        XCTAssertEqual(reply.agentSessionID, "beacon-session")
    }
}
