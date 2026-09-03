import XCTest
import RaiCore
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

        let result = await connection.sendComposedLine(line("hello"), to: "p1")

        XCTAssertEqual(result, .queued)
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

    func testPasswordPromptDropsOnlyThatPanesQueuedLines() async {
        let connection = BridgeConnection()
        _ = await connection.sendComposedLine(line("secret"), to: "pane-a")
        _ = await connection.sendComposedLine(line("keep"), to: "pane-b")

        connection.updateVisibleGrid("output\n[sudo] password for yogev:", for: "pane-a")
        let result = await connection.sendComposedLine(line("still secret"), to: "pane-a")

        XCTAssertEqual(result, .refused)
        XCTAssertEqual(connection.outbox.map(\.paneID), ["pane-b"])
        XCTAssertEqual(
            connection.actionError,
            PasswordPromptGuard.refusal + " 1 queued line for this pane was dropped."
        )
    }

    func testNotificationReplyUsesCurrentPasswordPromptGrid() async throws {
        let connection = BridgeConnection(messageSender: { _ in })
        let pairing = try Pairing(host: "studio.local", port: 9_876, token: "secret")
        connection.finishAuthentication(
            protocolVersion: bridgeProtocolVersion,
            sessionName: nil
        )
        connection.handle(frame("Password:\u{1B}[0m", paneID: "pane-a"))

        let delivered = await connection.connectAndSendComposedLine(
            line("secret"), to: "pane-a", pairing: pairing
        )

        XCTAssertFalse(delivered)
        XCTAssertEqual(connection.actionError, PasswordPromptGuard.refusal)
        XCTAssertTrue(connection.outbox.isEmpty)
    }

    func testReconnectWaitsForCurrentGridBeforeFlushing() async throws {
        var sentInputs: [String] = []
        let connection = BridgeConnection(messageSender: { message in
            if case let .input(_, bytesBase64) = message,
               let data = Data(base64Encoded: bytesBase64) {
                sentInputs.append(String(decoding: data, as: UTF8.self))
            }
        })
        connection.updateVisibleGrid("$", for: "pane-a")
        _ = await connection.sendComposedLine(line("held"), to: "pane-a")

        connection.finishAuthentication(
            protocolVersion: bridgeProtocolVersion,
            sessionName: nil
        )
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(sentInputs.isEmpty)
        XCTAssertEqual(connection.outbox.map(\.text), ["held\r"])
        XCTAssertEqual(connection.actionError, PasswordPromptGuard.waiting)

        connection.handle(frame("Password:\u{1B}[0m", paneID: "pane-a"))
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(sentInputs.isEmpty)
        XCTAssertTrue(connection.outbox.isEmpty)
        XCTAssertTrue(connection.actionError?.hasPrefix(PasswordPromptGuard.refusal) == true)

        connection.handle(frame("$", paneID: "pane-a"))
        let result = await connection.sendComposedLine(line("safe"), to: "pane-a")

        XCTAssertEqual(result, .accepted)
        XCTAssertEqual(sentInputs, ["safe\r"])
    }

    func testFlushSendsOneLineThenWaitsForANewerFrame() async throws {
        var sentInputs: [String] = []
        let connection = BridgeConnection(messageSender: { message in
            if case let .input(_, bytesBase64) = message,
               let data = Data(base64Encoded: bytesBase64) {
                sentInputs.append(String(decoding: data, as: UTF8.self))
            }
        })
        _ = await connection.sendComposedLine(line("first"), to: "pane-a")
        _ = await connection.sendComposedLine(line("second"), to: "pane-a")
        connection.finishAuthentication(
            protocolVersion: bridgeProtocolVersion,
            sessionName: nil
        )

        connection.handle(frame("$", paneID: "pane-a"))
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(sentInputs, ["first\r"])
        XCTAssertEqual(connection.outbox.map(\.text), ["second\r"])

        connection.handle(frame("Password:\u{1B}[0m", paneID: "pane-a"))
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(sentInputs, ["first\r"])
        XCTAssertTrue(connection.outbox.isEmpty)
        XCTAssertTrue(connection.actionError?.hasPrefix(PasswordPromptGuard.refusal) == true)
    }

    func testUnknownGridHoldStillExpiresOnANewFrame() async throws {
        var currentTime = Date(timeIntervalSince1970: 1_000)
        var sentInputs: [String] = []
        let connection = BridgeConnection(
            messageSender: { message in
                if case let .input(_, bytesBase64) = message,
                   let data = Data(base64Encoded: bytesBase64) {
                    sentInputs.append(String(decoding: data, as: UTF8.self))
                }
            },
            now: { currentTime }
        )
        _ = await connection.sendComposedLine(line("old"), to: "pane-a")
        connection.finishAuthentication(
            protocolVersion: bridgeProtocolVersion,
            sessionName: nil
        )
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(connection.outbox.map(\.text), ["old\r"])

        currentTime.addTimeInterval(15 * 60 + 1)
        connection.handle(frame("$", paneID: "pane-a"))
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(sentInputs.isEmpty)
        XCTAssertTrue(connection.outbox.isEmpty)
        XCTAssertEqual(connection.actionError, "1 queued line expired unsent")
    }

    func testReplyTimeoutReplacesWaitingAndKeepsDraft() async throws {
        let connection = BridgeConnection(
            messageSender: { _ in },
            replyFrameWaitIterations: 1
        )
        let pairing = try Pairing(host: "studio.local", port: 9_876, token: "secret")
        connection.finishAuthentication(
            protocolVersion: bridgeProtocolVersion,
            sessionName: nil
        )

        let delivered = await connection.connectAndSendComposedLine(
            line("keep me"), to: "pane-a", pairing: pairing
        )

        XCTAssertFalse(delivered)
        XCTAssertEqual(connection.actionError, PasswordPromptGuard.verificationFailure)
        XCTAssertEqual(connection.takePendingComposedDraft(for: "pane-a"), "keep me")
    }

    private func frame(_ text: String, paneID: String) -> BridgeMessage {
        .paneFrame(
            paneID: paneID,
            bytesBase64: Data(("\u{1B}[H" + text).utf8).base64EncodedString(),
            full: true,
            seq: 0,
            cols: 80,
            rows: 24
        )
    }
}
