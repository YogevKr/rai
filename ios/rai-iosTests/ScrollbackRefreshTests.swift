import RaiCore
import XCTest
@testable import rai

@MainActor
final class ScrollbackRefreshTests: XCTestCase {
    private final class Messages {
        var values: [BridgeMessage] = []
        var readCount: Int {
            values.filter { if case .readScrollback = $0 { return true }; return false }.count
        }
        var attachCount: Int {
            values.filter { if case .attachStream = $0 { return true }; return false }.count
        }
    }

    private func connected(_ messages: Messages) async throws -> BridgeConnection {
        let connection = BridgeConnection(messageSender: { messages.values.append($0) })
        connection.finishAuthentication(protocolVersion: bridgeProtocolVersion, sessionName: nil)
        _ = connection.addPaneFrameHandler(for: "pane") { _, _, _ in }
        connection.openPane(paneID: "pane")
        try await Task.sleep(for: .milliseconds(30))
        connection.handle(.scrollback(paneID: "pane", bytesBase64: ""))
        return connection
    }

    private func frame(_ connection: BridgeConnection) {
        connection.handle(.paneFrame(
            paneID: "pane", bytesBase64: Data("\u{1B}[Hupdated".utf8).base64EncodedString(),
            full: false, seq: 1, cols: 80, rows: 24
        ))
    }

    func testOutputCoalescesReadsAndKeepsOnlyOneRequestInFlight() async throws {
        let messages = Messages()
        let connection = try await connected(messages)
        defer { connection.disconnect() }
        let initialReads = messages.readCount
        let initialAttaches = messages.attachCount
        for _ in 0..<30 { frame(connection) }
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(messages.readCount, initialReads + 1)
        for _ in 0..<30 { frame(connection) }
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(messages.readCount, initialReads + 1, "A slow read cannot create a request backlog")
        connection.handle(.scrollback(paneID: "pane", bytesBase64: ""))
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(messages.readCount, initialReads + 2, "Output during the read gets one follow-up")
        XCTAssertEqual(messages.attachCount, initialAttaches, "History updates do not restart the stream")
        connection.handle(.scrollback(paneID: "pane", bytesBase64: ""))
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(messages.readCount, initialReads + 2, "Idle panes stop reading")
    }

    func testDetachCancelsTheScheduledHistoryRead() async throws {
        let messages = Messages()
        let connection = try await connected(messages)
        defer { connection.disconnect() }
        let initialReads = messages.readCount
        frame(connection)
        connection.detachPane(paneID: "pane")
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(messages.readCount, initialReads)
    }

    func testDisconnectCancelsTheScheduledHistoryRead() async throws {
        let messages = Messages()
        let connection = try await connected(messages)
        let initialReads = messages.readCount
        frame(connection)
        connection.disconnect()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(messages.readCount, initialReads)
    }

    func testLateReplyAfterDetachDoesNotSkipTheNextSeed() async throws {
        let messages = Messages()
        let connection = try await connected(messages)
        defer { connection.disconnect() }
        var delivered = 0
        _ = connection.addPaneScrollbackHandler(for: "pane") { _ in delivered += 1 }
        connection.detachPane(paneID: "pane")
        let before = delivered
        connection.handle(.scrollback(paneID: "pane", bytesBase64: ""))
        XCTAssertEqual(delivered, before)
        let reads = messages.readCount
        connection.openPane(paneID: "pane")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(messages.readCount, reads + 1)
    }

    func testFailedReadRetriesOnlyAfterMoreOutput() async throws {
        let messages = Messages()
        let connection = try await connected(messages)
        defer { connection.disconnect() }
        frame(connection)
        try await Task.sleep(for: .milliseconds(350))
        let reads = messages.readCount
        connection.handle(.error(message: "Could not read scrollback", code: .scrollbackUnavailable, detail: "pane"))
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(messages.readCount, reads)
        frame(connection)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(messages.readCount, reads + 1)
    }

    func testStreamRestartReleasesACancelledServerRead() async throws {
        let messages = Messages()
        let connection = try await connected(messages)
        defer { connection.disconnect() }
        frame(connection)
        try await Task.sleep(for: .milliseconds(350))
        let reads = messages.readCount
        connection.handle(.paneFrame(
            paneID: "pane", bytesBase64: "", full: true, seq: 1, cols: 80, rows: 30
        ))
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(messages.readCount, reads + 1)
    }

    func testFailedReadKeepsOutputThatArrivedDuringTheRequest() async throws {
        let messages = Messages()
        let connection = try await connected(messages)
        defer { connection.disconnect() }
        frame(connection)
        try await Task.sleep(for: .milliseconds(350))
        let reads = messages.readCount
        frame(connection)
        let error = BridgeMessage.error(
            message: "Could not read scrollback", code: .scrollbackUnavailable, detail: "pane"
        )
        connection.handle(error)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(messages.readCount, reads + 1)
        connection.handle(error)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(messages.readCount, reads + 1, "A failed idle read does not loop")
    }

    func testOutputCanRecoverFromAnUnavailableInitialSeed() async throws {
        let messages = Messages()
        let connection = BridgeConnection(messageSender: { messages.values.append($0) })
        connection.finishAuthentication(protocolVersion: bridgeProtocolVersion, sessionName: nil)
        defer { connection.disconnect() }
        _ = connection.addPaneFrameHandler(for: "pane") { _, _, _ in }
        connection.openPane(paneID: "pane")
        try await Task.sleep(for: .milliseconds(30))
        let reads = messages.readCount
        connection.handle(.error(
            message: "Could not read scrollback", code: .scrollbackUnavailable, detail: "pane"
        ))
        frame(connection)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(messages.readCount, reads + 1)
    }
}
