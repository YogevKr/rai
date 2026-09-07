import Foundation
import RaiCore
import XCTest
@testable import rai

@MainActor
final class BridgeNetworkTests: XCTestCase {
    private final class Socket: BridgeSocket {
        var messages: [BridgeMessage] = []
        var cancelCount = 0
        var pongs: [@Sendable (Error?) -> Void] = []
        var receiver: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
        var pendingInput: CheckedContinuation<Void, Error>?
        var delaysInput = false

        func resume() {}
        func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
            cancelCount += 1
            receiver?.resume(throwing: URLError(.networkConnectionLost))
            receiver = nil
        }
        func receive() async throws -> URLSessionWebSocketTask.Message {
            if cancelCount > 0 { throw CancellationError() }
            return try await withCheckedThrowingContinuation { receiver = $0 }
        }
        func send(_ message: URLSessionWebSocketTask.Message) async throws {
            guard case let .string(text) = message else { return }
            let value = try JSONDecoder().decode(BridgeMessage.self, from: Data(text.utf8))
            messages.append(value)
            if case .input = value, delaysInput {
                try await withCheckedThrowingContinuation { pendingInput = $0 }
            }
        }
        func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void) {
            pongs.append(pongReceiveHandler)
        }
    }

    @MainActor
    private final class Network {
        var sockets: [Socket] = []
        func make(_ url: URL) -> any BridgeSocket {
            let socket = Socket()
            sockets.append(socket)
            return socket
        }
    }

    private func connection(
        _ network: Network,
        handshake: TimeInterval = 1,
        pong: TimeInterval = 1,
        pingInterval: TimeInterval = 10
    ) throws -> BridgeConnection {
        let connection = BridgeConnection(
            socketFactory: network.make,
            networkTiming: BridgeNetworkTiming(
                handshakeTimeout: handshake, pingInterval: pingInterval,
                pongTimeout: pong, reconnectBase: 0.02
            ),
            monitorsNetwork: false
        )
        try connection.connect(to: Pairing(host: "127.0.0.1", port: 12345, token: "test"))
        return connection
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    func testStalledHandshakeClosesSocketAndRetries() async throws {
        let network = Network()
        let connection = try connection(network, handshake: 0.08)
        defer { connection.disconnect() }
        await eventually { network.sockets.count == 2 }
        XCTAssertEqual(network.sockets[0].cancelCount, 1)
    }

    func testRecoveryCoversBackoffHandshakeAndNetworkWait() async throws {
        let network = Network()
        let connection = try connection(network)
        defer { connection.disconnect() }
        connection.finishAuthentication(protocolVersion: bridgeProtocolVersion, sessionName: nil)
        XCTAssertFalse(connection.isRecoveringConnection)

        connection.scheduleReconnect(after: URLError(.networkConnectionLost))
        XCTAssertTrue(connection.isRecoveringConnection)
        await eventually { network.sockets.count == 2 }
        XCTAssertFalse(connection.hasPendingReconnect)
        XCTAssertTrue(connection.isRecoveringConnection, "The handshake is still recovering the same outage")

        connection.finishAuthentication(protocolVersion: bridgeProtocolVersion, sessionName: nil)
        XCTAssertFalse(connection.isRecoveringConnection)
        connection.networkPathChanged(.init(status: .unsatisfied, interfaces: []))
        XCTAssertTrue(connection.isRecoveringConnection, "Network return restarts recovery automatically")
    }

    func testQueuedLinesDoNotReplaceSlowHandshake() async throws {
        let network = Network()
        let connection = try connection(network)
        defer { connection.disconnect() }
        for line in ["first", "second", "third"] {
            _ = await connection.sendComposedLine(Array((line + "\r").utf8), to: "pane")
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(network.sockets.count, 1)
        XCTAssertEqual(network.sockets[0].cancelCount, 0)
        XCTAssertEqual(connection.outbox.count, 3)
        connection.finishAuthentication(protocolVersion: bridgeProtocolVersion, sessionName: nil)
        XCTAssertTrue(connection.status.isConnected)
    }

    func testMissingPongReplacesDeadSocket() async throws {
        let network = Network()
        let connection = try connection(network, pong: 0.08)
        defer { connection.disconnect() }
        connection.finishAuthentication(protocolVersion: bridgeProtocolVersion, sessionName: nil)
        await eventually { network.sockets.count == 2 }
        XCTAssertEqual(network.sockets[0].cancelCount, 1)
        XCTAssertEqual(network.sockets[0].pongs.count, 1)
    }

    func testSlowPongKeepsConnectionAndLateOldPongCannotCloseNewSocket() async throws {
        let network = Network()
        let connection = try connection(network, pong: 0.5)
        defer { connection.disconnect() }
        connection.finishAuthentication(protocolVersion: bridgeProtocolVersion, sessionName: nil)
        try await Task.sleep(for: .milliseconds(150))
        network.sockets[0].pongs[0](nil)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(connection.status.isConnected)
        XCTAssertEqual(network.sockets.count, 1)

        connection.retryNow()
        connection.finishAuthentication(protocolVersion: bridgeProtocolVersion, sessionName: nil)
        network.sockets[0].pongs[0](URLError(.networkConnectionLost))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(connection.status.isConnected)
        XCTAssertEqual(network.sockets.count, 2)
        XCTAssertEqual(network.sockets[1].cancelCount, 0)
    }

    func testOfflineWaitsAndNetworkReturnReconnectsImmediately() async throws {
        let network = Network()
        let connection = try connection(network)
        defer { connection.disconnect() }
        connection.networkPathChanged(BridgeNetworkPath(status: .satisfied, interfaces: ["wifi"]))
        connection.networkPathChanged(BridgeNetworkPath(status: .unsatisfied))
        _ = await connection.sendComposedLine(Array("held\r".utf8), to: "pane")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(network.sockets.count, 1)
        XCTAssertFalse(connection.hasPendingReconnect)
        connection.networkPathChanged(BridgeNetworkPath(
            status: .satisfied, isExpensive: true, interfaces: ["cellular"]
        ))
        XCTAssertEqual(network.sockets.count, 2)
        XCTAssertEqual(connection.scrollbackRefreshInterval, 2)
    }

    func testHandoffReconnectsButCostChangeDoesNot() throws {
        let network = Network()
        let connection = try connection(network)
        defer { connection.disconnect() }
        connection.networkPathChanged(BridgeNetworkPath(status: .satisfied, interfaces: ["wifi"]))
        connection.networkPathChanged(BridgeNetworkPath(
            status: .satisfied, isConstrained: true, interfaces: ["wifi"]
        ))
        XCTAssertEqual(network.sockets.count, 1)
        XCTAssertEqual(connection.scrollbackRefreshInterval, 2)
        connection.networkPathChanged(BridgeNetworkPath(status: .satisfied, interfaces: ["cellular"]))
        XCTAssertEqual(network.sockets.count, 2)
    }

    func testActivationRequiredPathAllowsHandshakeAndAutomaticRetry() async throws {
        let network = Network()
        let connection = try connection(network, handshake: 0.08)
        defer { connection.disconnect() }
        connection.networkPathChanged(BridgeNetworkPath(status: .requiresConnection))
        XCTAssertEqual(network.sockets[0].cancelCount, 0, "The attempt may activate the network")
        await eventually { network.sockets.count >= 2 }
        XCTAssertGreaterThanOrEqual(network.sockets.count, 2, "Activation must not block retry backoff")
    }

    func testOfflinePathCanActivateWithoutCancellingTheNewHandshake() throws {
        let network = Network()
        let connection = try connection(network)
        defer { connection.disconnect() }
        connection.networkPathChanged(BridgeNetworkPath(status: .unsatisfied))
        connection.networkPathChanged(BridgeNetworkPath(status: .requiresConnection))
        XCTAssertEqual(network.sockets.count, 2)
        connection.networkPathChanged(BridgeNetworkPath(status: .satisfied, interfaces: ["wifi"]))
        XCTAssertEqual(network.sockets.count, 2, "Activating the path must keep the new socket")
        XCTAssertEqual(network.sockets[1].cancelCount, 0)
        connection.retryNow()
        XCTAssertEqual(network.sockets.count, 3)
    }

    func testLateInputFailureCannotDisconnectReplacementOrReplayInput() async throws {
        let network = Network()
        let connection = try connection(network)
        defer { connection.disconnect() }
        connection.finishAuthentication(protocolVersion: bridgeProtocolVersion, sessionName: nil)
        network.sockets[0].delaysInput = true
        connection.sendInput(Array("x".utf8), to: "pane")
        await eventually { network.sockets[0].pendingInput != nil }
        connection.retryNow()
        connection.finishAuthentication(protocolVersion: bridgeProtocolVersion, sessionName: nil)
        network.sockets[0].pendingInput?.resume(throwing: URLError(.networkConnectionLost))
        network.sockets[0].pendingInput = nil
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(connection.status.isConnected)
        XCTAssertEqual(network.sockets.count, 2)
        XCTAssertFalse(network.sockets[1].messages.contains { if case .input = $0 { return true }; return false })
    }

    func testSuccessfulComposedLineIsNotQueuedWhenSocketChangesBeforeCompletion() async throws {
        let network = Network()
        let connection = try connection(network)
        defer { connection.disconnect() }
        connection.finishAuthentication(protocolVersion: bridgeProtocolVersion, sessionName: nil)
        connection.updateVisibleGrid("$", for: "pane")
        network.sockets[0].delaysInput = true
        let send = Task { await connection.sendComposedLine(Array("once\r".utf8), to: "pane") }
        await eventually { network.sockets[0].pendingInput != nil }
        connection.retryNow()
        connection.finishAuthentication(protocolVersion: bridgeProtocolVersion, sessionName: nil)
        network.sockets[0].pendingInput?.resume(returning: ())
        network.sockets[0].pendingInput = nil
        let result = await send.value
        XCTAssertEqual(result, .accepted)
        XCTAssertTrue(connection.outbox.isEmpty)
        XCTAssertFalse(network.sockets[1].messages.contains { if case .input = $0 { return true }; return false })
    }

    func testDisconnectCancelsDeadlinesAndIgnoresNetworkChanges() async throws {
        let network = Network()
        let connection = try connection(network, handshake: 0.08, pong: 0.08)
        connection.finishAuthentication(protocolVersion: bridgeProtocolVersion, sessionName: nil)
        connection.disconnect()
        connection.networkPathChanged(BridgeNetworkPath(status: .unsatisfied))
        connection.networkPathChanged(BridgeNetworkPath(status: .satisfied))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(network.sockets.count, 1)
        XCTAssertEqual(connection.status, .disconnected)
    }

    func testLegacyPingErrorDoesNotHideApplicationErrors() throws {
        let network = Network()
        let connection = try connection(network)
        defer { connection.disconnect() }
        connection.finishAuthentication(protocolVersion: bridgeProtocolVersion, sessionName: nil)
        connection.handle(.error(
            message: "Only WebSocket text frames are supported.", code: .invalidRequest,
            detail: "The bridge accepts WebSocket text frames only."
        ))
        XCTAssertNil(connection.actionError)
        connection.handle(.error(message: "Invalid pane size", code: .invalidRequest))
        XCTAssertEqual(connection.actionError, "Invalid pane size")
    }

    func testLiveSnapshotResumesPingsAfterMissingHerdRecovers() async throws {
        let network = Network()
        let connection = try connection(network, pingInterval: 0.02)
        defer { connection.disconnect() }
        connection.finishAuthentication(protocolVersion: bridgeProtocolVersion, sessionName: nil)
        network.sockets[0].pongs[0](nil)
        connection.handle(.error(message: "Herdr is not connected.", code: .herdMissing))
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(connection.status.isConnected)
        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data("""
        {"version":"test","protocol":1,"layouts":[],"panes":[],"workspaces":[],"tabs":[]}
        """.utf8))
        connection.replaceWithLiveSnapshot(snapshot)
        XCTAssertTrue(connection.status.isConnected)
        XCTAssertEqual(network.sockets[0].pongs.count, 2)
    }

    func testSlowHistoryAndHighLatencyReduceReadRate() {
        var pacing = BridgeHistoryPacing()
        XCTAssertEqual(pacing.interval, 0.25)
        pacing.roundTrip = 1
        XCTAssertEqual(pacing.interval, 2)
        pacing.historyReadDuration = 9
        XCTAssertEqual(pacing.interval, 5)
        pacing.historyReadDuration = 0.1
        pacing.roundTrip = 0.1
        XCTAssertEqual(pacing.interval, 0.25)
    }
}
