import Foundation
import Network
import RaiCore
import XCTest
@testable import rai

@MainActor
final class BridgeSocketIntegrationTests: XCTestCase {
    /// A loopback bridge with the same WebSocket control-frame policy as the Mac.
    @MainActor
    private final class Server {
        let listener: NWListener
        let queue = DispatchQueue(label: "rai.tests.loopback-bridge")
        var clients: [NWConnection] = []
        var port: UInt16?
        var nonTextMessages = 0
        var historyResponseSizes: [Int] = []
        var inputCount = 0
        let history = Data(String(repeating: "retained history row\n", count: 1_000).utf8)

        init() throws {
            let parameters = NWParameters.tcp
            let websocket = NWProtocolWebSocket.Options()
            websocket.autoReplyPing = true
            parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
            listener = try NWListener(using: parameters, on: .any)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    if case .ready = state { self?.port = self?.listener.port?.rawValue }
                }
            }
            listener.newConnectionHandler = { [weak self] client in
                Task { @MainActor [weak self] in
                    guard let self else { client.cancel(); return }
                    self.clients.append(client)
                    client.start(queue: self.queue)
                    self.receive(client)
                }
            }
            listener.start(queue: queue)
        }

        func stop() {
            listener.cancel()
            for client in clients { client.cancel() }
        }

        func receive(_ client: NWConnection) {
            client.receiveMessage { [weak self] data, context, _, error in
                Task { @MainActor [weak self] in
                    guard let self, error == nil else { return }
                    let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                        as? NWProtocolWebSocket.Metadata
                    switch BridgeWebSocketPolicy.action(for: metadata?.opcode) {
                    case .ignore:
                        break
                    case .close:
                        client.cancel()
                        return
                    case .reject:
                        self.nonTextMessages += 1
                        self.send(.error(message: "Only text frames", code: .invalidRequest), to: client)
                    case .text:
                        if let data,
                              let message = try? JSONDecoder().decode(BridgeMessage.self, from: data) {
                            switch message {
                            case .hello:
                                // Exercise a slow application handshake over the real URLSession transport.
                                try? await Task.sleep(for: .milliseconds(200))
                                self.send(.welcome(protocolVersion: bridgeProtocolVersion, sessionName: "test"), to: client)
                            case let .readScrollback(paneID, _, _, _, knownHash):
                                let reply = PaneScrollback.reply(paneID: paneID, payload: self.history, knownHash: knownHash)
                                self.historyResponseSizes.append((try? JSONEncoder().encode(reply).count) ?? 0)
                                self.send(reply, to: client)
                            case .input:
                                self.inputCount += 1
                            default:
                                break
                            }
                        }
                    }
                    self.receive(client)
                }
            }
        }

        func send(_ message: BridgeMessage, to client: NWConnection) {
            guard let data = try? JSONEncoder().encode(message) else { return }
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "test-text", metadata: [metadata])
            client.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
        }
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(4)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    func testDelayedBridgeConditionalHistoryPingAndReconnect() async throws {
        let server = try Server()
        defer { server.stop() }
        await eventually { server.port != nil }
        let connection = BridgeConnection(
            networkTiming: BridgeNetworkTiming(
                handshakeTimeout: 2, pingInterval: 0.1, pongTimeout: 1, reconnectBase: 0.02
            ), monitorsNetwork: false
        )
        defer { connection.disconnect() }
        try connection.connect(to: Pairing(host: "127.0.0.1", port: Int(try XCTUnwrap(server.port)), token: "test"))
        await eventually { connection.status.isConnected }
        var histories: [Data] = []
        _ = connection.addPaneScrollbackHandler(for: "pane") { histories.append($0) }
        connection.openPane(paneID: "pane")
        await eventually { histories.count == 1 }
        XCTAssertEqual(histories.first, server.history)
        connection.detachPane(paneID: "pane")
        try await Task.sleep(for: .milliseconds(30))
        connection.restoreScrollbackHash(PaneScrollback.contentHash(server.history), paneID: "pane")
        connection.openPane(paneID: "pane")
        await eventually { server.historyResponseSizes.count == 2 }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(histories.count, 1, "The second visit keeps its history")
        XCTAssertLessThan(server.historyResponseSizes[1] * 100, server.historyResponseSizes[0])
        XCTAssertEqual(server.nonTextMessages, 0, "Ping frames must not produce request errors")
        XCTAssertNil(connection.actionError)
        XCTAssertTrue(connection.status.isConnected)

        connection.sendInput(Array("x".utf8), to: "pane")
        await eventually { server.inputCount == 1 }
        server.clients.first?.cancel()
        await eventually { server.clients.count == 2 && connection.status.isConnected }
        XCTAssertEqual(server.inputCount, 1, "Reconnect must not replay raw keys")
    }
}
