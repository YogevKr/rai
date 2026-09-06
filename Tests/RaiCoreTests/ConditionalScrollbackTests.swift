import Foundation
import XCTest
@testable import RaiCore

final class ConditionalScrollbackTests: XCTestCase {
    func testWebSocketControlFramesStayOutsideRequestDecoding() {
        XCTAssertEqual(BridgeWebSocketPolicy.action(for: .ping), .ignore)
        XCTAssertEqual(BridgeWebSocketPolicy.action(for: .pong), .ignore)
        XCTAssertEqual(BridgeWebSocketPolicy.action(for: .close), .close)
        XCTAssertEqual(BridgeWebSocketPolicy.action(for: .text), .text)
        XCTAssertEqual(BridgeWebSocketPolicy.action(for: .binary), .reject)
        XCTAssertEqual(BridgeWebSocketPolicy.action(for: nil), .reject)
    }

    func testUnchangedHistoryAvoidsPayloadAndChangedHistoryReplacesIt() throws {
        let history = Data(String(repeating: "history line with colors\n", count: 1_000).utf8)
        let hash = PaneScrollback.contentHash(history)
        let response = PaneScrollback.reply(paneID: "pane", payload: history, knownHash: hash)
        XCTAssertEqual(response, .scrollbackUnchanged(paneID: "pane", contentHash: hash))
        let encoded = try JSONEncoder().encode(response)
        XCTAssertLessThan(encoded.count, 160)
        XCTAssertLessThan(encoded.count * 100, history.base64EncodedData().count)
        XCTAssertEqual(try JSONDecoder().decode(BridgeMessage.self, from: encoded), response)

        let changed = history + Data("new line\n".utf8)
        XCTAssertEqual(
            PaneScrollback.reply(paneID: "pane", payload: changed, knownHash: hash),
            .scrollback(paneID: "pane", bytesBase64: changed.base64EncodedString())
        )
        XCTAssertEqual(
            PaneScrollback.reply(paneID: "pane", payload: Data(), knownHash: hash),
            .scrollback(paneID: "pane", bytesBase64: ""),
            "An empty changed history must clear retained rows"
        )
    }

    func testOldRequestsStillReceiveFullHistory() throws {
        let request = Data("""
        {"type":"readScrollback","paneID":"pane","lines":1000,"rows":24,"fullGrid":true}
        """.utf8)
        let decoded = try JSONDecoder().decode(BridgeMessage.self, from: request)
        guard case let .readScrollback(paneID, _, _, _, knownHash) = decoded else { return XCTFail() }
        XCTAssertNil(knownHash)
        let history = Data("old client\n".utf8)
        XCTAssertEqual(
            PaneScrollback.reply(paneID: paneID, payload: history, knownHash: knownHash),
            .scrollback(paneID: paneID, bytesBase64: history.base64EncodedString())
        )
        let conditional = BridgeMessage.readScrollback(
            paneID: paneID, lines: 1000, rows: 24, fullGrid: true,
            knownHash: PaneScrollback.contentHash(history)
        )
        XCTAssertEqual(
            try JSONDecoder().decode(BridgeMessage.self, from: JSONEncoder().encode(conditional)),
            conditional
        )
    }
}
