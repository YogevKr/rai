import XCTest
@testable import rai

/// A composed line typed with no signal used to be lost twice over: the send
/// threw into `handleSocketFailure`, and the compose field cleared regardless,
/// so the text was gone with nothing to say so. These pin the contract the
/// compose bar now relies on.
@MainActor
final class OutboxTests: XCTestCase {
    private func line(_ text: String) -> [UInt8] { Array(text.utf8) + [0x0D] }

    func testDisconnectedSendQueuesInsteadOfDropping() async {
        let connection = BridgeConnection()
        XCTAssertFalse(connection.status.isConnected)

        let delivered = await connection.sendComposedLine(line("hello"), to: "p1")

        // False is what keeps the user's text in the compose field.
        XCTAssertFalse(delivered)
        XCTAssertEqual(connection.outbox.count, 1)
        XCTAssertEqual(connection.outbox.first?.paneID, "p1")
        XCTAssertEqual(connection.outbox.first?.text, "hello\r")
    }

    func testQueueKeepsSubmissionOrder() async {
        let connection = BridgeConnection()
        for word in ["first", "second", "third"] {
            _ = await connection.sendComposedLine(line(word), to: "p1")
        }
        XCTAssertEqual(
            connection.outbox.map(\.text),
            ["first\r", "second\r", "third\r"]
        )
    }

    func testQueueIsBoundedAndDropsOldestFirst() async {
        let connection = BridgeConnection()
        // One past the cap, so the oldest must fall off the front.
        for index in 0..<25 {
            _ = await connection.sendComposedLine(line("line\(index)"), to: "p1")
        }
        XCTAssertLessThanOrEqual(connection.outbox.count, 20)
        XCTAssertEqual(connection.outbox.last?.text, "line24\r")
        // line0 is long gone; a phone left offline must not build an unbounded
        // replay that lands all at once later.
        XCTAssertFalse(connection.outbox.contains { $0.text == "line0\r" })
    }

    func testDiscardClearsTheQueue() async {
        let connection = BridgeConnection()
        _ = await connection.sendComposedLine(line("hello"), to: "p1")
        XCTAssertEqual(connection.outbox.count, 1)

        connection.discardOutbox()

        XCTAssertTrue(connection.outbox.isEmpty)
    }

    func testQueuedLinesCarryPaneIdentityNotJustText() async {
        let connection = BridgeConnection()
        _ = await connection.sendComposedLine(line("a"), to: "pane-a")
        _ = await connection.sendComposedLine(line("b"), to: "pane-b")

        // Replay has to reach the pane the line was typed for, not whichever
        // pane happens to be open when the connection returns.
        XCTAssertEqual(connection.outbox.map(\.paneID), ["pane-a", "pane-b"])
    }
}
