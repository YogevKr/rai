import Foundation

public enum HerdrClientError: LocalizedError {
    case invalidEnvelope
    case remote(code: String, message: String)
    case invalidEvent
    case disconnected

    public var errorDescription: String? {
        switch self {
        case .invalidEnvelope:
            return "Herdr returned an invalid response envelope"
        case .remote(let code, let message):
            return "\(code): \(message)"
        case .invalidEvent:
            return "Herdr returned an invalid event envelope"
        case .disconnected:
            return "Disconnected from Herdr"
        }
    }
}

private struct RPCRequest: Encodable {
    let id: String
    let method: String
    let params: [String: JSONValue]
}

private struct RPCErrorBody: Decodable {
    let code: String
    let message: String
}

private struct RPCEnvelope: Decodable {
    let id: String?
    let result: JSONValue?
    let error: RPCErrorBody?
    let event: JSONValue?
    let data: [String: JSONValue]?
}

private final class EventWorkerState: @unchecked Sendable {
    private let lock = NSLock()
    private var socket: UnixSocket?
    private var stopped = false

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func install(_ socket: UnixSocket) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return false }
        self.socket = socket
        return true
    }

    func clear() {
        lock.lock()
        socket = nil
        lock.unlock()
    }

    func stop() {
        lock.lock()
        stopped = true
        let socket = socket
        self.socket = nil
        lock.unlock()
        socket?.close()
    }
}

private final class RPCSocketState: @unchecked Sendable {
    private let lock = NSLock()
    private var socket: UnixSocket?
    private var stopped = false

    var current: UnixSocket? {
        lock.lock()
        defer { lock.unlock() }
        return socket
    }

    func install(_ socket: UnixSocket) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return false }
        self.socket = socket
        return true
    }

    func discard(_ socket: UnixSocket) {
        lock.lock()
        if self.socket === socket {
            self.socket = nil
        }
        lock.unlock()
        socket.close()
    }

    func stop() {
        lock.lock()
        stopped = true
        let socket = socket
        self.socket = nil
        lock.unlock()
        socket?.close()
    }
}

public actor HerdrClient {
    public static let defaultSubscriptions = [
        "layout.updated",
        "pane.created",
        "pane.closed",
        "pane.moved",
        "pane.focused",
        "pane.agent_status_changed",
        "pane.output_changed",
        "tab.closed",
        "tab.moved",
        "workspace.focused",
        "workspace.moved",
    ]

    public nonisolated let socketPath: String

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private nonisolated let rpcSocketState = RPCSocketState()
    private var nextID = 1

    public init(socketPath: String = HerdrClient.defaultSocketPath()) {
        self.socketPath = socketPath
    }

    public nonisolated static func defaultSocketPath() -> String {
        let configured = ProcessInfo.processInfo.environment["HERDR_SOCKET_PATH"]
            ?? "~/.config/herdr/herdr.sock"
        return NSString(string: configured).expandingTildeInPath
    }

    /// Immediately closes the RPC transport, including a blocked read.
    ///
    /// A disconnected client is intentionally single-use. Runtime herd changes
    /// build a fresh client so no request can leak across connection generations.
    public nonisolated func disconnect() {
        rpcSocketState.stop()
    }

    public func snapshot() async throws -> SessionSnapshot {
        let result: SnapshotResult = try call(method: "session.snapshot", params: [:])
        return result.snapshot
    }

    public func readPane(
        paneID: String,
        source: String = "visible",
        lines: Int? = nil,
        format: String = "ansi"
    ) async throws -> PaneRead {
        var params: [String: JSONValue] = [
            "pane_id": .string(paneID),
            "source": .string(source),
            "format": .string(format),
            "strip_ansi": .bool(false),
        ]
        if let lines {
            params["lines"] = .number(Double(lines))
        }
        let result: PaneReadResult = try call(method: "pane.read", params: params)
        return result.read
    }

    public func sendInput(paneID: String, bytes: [UInt8]) async throws {
        if bytes == [0x0D] || bytes == [0x0A] {
            let _: JSONValue = try call(
                method: "pane.send_input",
                params: [
                    "pane_id": .string(paneID),
                    "keys": .array([.string("enter")]),
                ]
            )
            return
        }
        let text = String(decoding: bytes, as: UTF8.self)
        let _: JSONValue = try call(
            method: "pane.send_input",
            params: ["pane_id": .string(paneID), "text": .string(text)]
        )
    }

    public func focusPane(_ paneID: String) async throws {
        let _: JSONValue = try call(
            method: "pane.focus",
            params: ["pane_id": .string(paneID)]
        )
    }

    /// Protocol 16 exposes pane.resize as directional split resizing.
    /// This intentionally does not pretend it accepts terminal rows/columns.
    public func resizePane(
        _ paneID: String,
        direction: String,
        amount: Double? = nil
    ) async throws {
        var params: [String: JSONValue] = [
            "pane_id": .string(paneID),
            "direction": .string(direction),
        ]
        if let amount {
            params["amount"] = .number(amount)
        }
        let _: JSONValue = try call(method: "pane.resize", params: params)
    }

    public func moveTab(_ tabID: String, insertIndex: Int) throws {
        let _: JSONValue = try call(
            method: "tab.move",
            params: [
                "tab_id": .string(tabID),
                "insert_index": .number(Double(insertIndex)),
            ]
        )
    }

    public func moveWorkspace(_ workspaceID: String, insertIndex: Int) throws {
        let _: JSONValue = try call(
            method: "workspace.move",
            params: [
                "workspace_id": .string(workspaceID),
                "insert_index": .number(Double(insertIndex)),
            ]
        )
    }

    public nonisolated func events(
        subscriptions: [String] = HerdrClient.defaultSubscriptions,
        paneIDs: [String] = []
    ) -> AsyncThrowingStream<HerdrEvent, Error> {
        let path = socketPath
        let state = EventWorkerState()
        var wireSubscriptions: [JSONValue] = []
        for type in subscriptions {
            switch type {
            case "pane.agent_status_changed":
                // Protocol 16 requires a pane filter for this subscription.
                wireSubscriptions.append(
                    contentsOf: paneIDs.map {
                        .object(["type": .string(type), "pane_id": .string($0)])
                    }
                )
            case "pane.output_changed":
                // The event exists in protocol 16 but cannot be subscribed to.
                // pane.updated plus the model's focused-pane poll is the compatibility path.
                continue
            default:
                wireSubscriptions.append(.object(["type": .string(type)]))
            }
        }
        if subscriptions.contains("pane.output_changed"),
           !subscriptions.contains("pane.updated") {
            wireSubscriptions.append(.object(["type": .string("pane.updated")]))
        }

        // Capture an immutable copy — a mutable `var` can't be captured by the
        // detached (concurrently-executing) closure under strict concurrency.
        let subscriptionsPayload = wireSubscriptions
        return AsyncThrowingStream { continuation in
            let worker = Task.detached {
                do {
                    let socket = try UnixSocket(path: path)
                    guard state.install(socket) else { return }
                    let request = RPCRequest(
                        id: "sub",
                        method: "events.subscribe",
                        params: [
                            "subscriptions": .array(subscriptionsPayload),
                        ]
                    )
                    try socket.writeLine(JSONEncoder().encode(request))

                    while !Task.isCancelled && !state.isStopped {
                        let line = try socket.readLine()
                        let envelope = try JSONDecoder().decode(RPCEnvelope.self, from: line)
                        if let error = envelope.error {
                            throw HerdrClientError.remote(
                                code: error.code,
                                message: error.message
                            )
                        }
                        guard let rawEvent = envelope.event else {
                            // The subscription acknowledgement is an ordinary RPC response.
                            continue
                        }
                        let event: HerdrEvent
                        switch rawEvent {
                        case .string(let name):
                            event = HerdrEvent(
                                name: Self.normalizedEventName(name),
                                data: envelope.data ?? [:]
                            )
                        case .object(let object):
                            guard let type = object["type"]?.stringValue else {
                                throw HerdrClientError.invalidEvent
                            }
                            event = HerdrEvent(
                                name: Self.normalizedEventName(type),
                                data: object
                            )
                        default:
                            throw HerdrClientError.invalidEvent
                        }
                        continuation.yield(event)
                    }
                    state.clear()
                    continuation.finish()
                } catch {
                    state.clear()
                    if !state.isStopped {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in
                state.stop()
                worker.cancel()
            }
        }
    }

    private nonisolated static func normalizedEventName(_ name: String) -> String {
        guard !name.contains("."), let separator = name.firstIndex(of: "_") else {
            return name
        }
        var normalized = name
        normalized.replaceSubrange(separator...separator, with: ".")
        return normalized
    }

    private func call<T: Decodable>(
        method: String,
        params: [String: JSONValue]
    ) throws -> T {
        let id = String(nextID)
        nextID += 1
        let request = try encoder.encode(RPCRequest(id: id, method: method, params: params))

        var lastTransportError: Error?
        for _ in 0..<2 {
            do {
                let socket: UnixSocket
                if let existing = rpcSocketState.current {
                    socket = existing
                } else {
                    socket = try UnixSocket(path: socketPath)
                    guard rpcSocketState.install(socket) else {
                        socket.close()
                        throw HerdrClientError.disconnected
                    }
                }
                try socket.writeLine(request)

                while true {
                    let line = try socket.readLine()
                    let envelope = try decoder.decode(RPCEnvelope.self, from: line)
                    guard envelope.id == id else { continue }
                    if let error = envelope.error {
                        throw HerdrClientError.remote(
                            code: error.code,
                            message: error.message
                        )
                    }
                    guard let result = envelope.result else {
                        throw HerdrClientError.invalidEnvelope
                    }
                    let resultData = try encoder.encode(result)
                    return try decoder.decode(T.self, from: resultData)
                }
            } catch let error as HerdrClientError {
                throw error
            } catch {
                lastTransportError = error
                if let socket = rpcSocketState.current {
                    rpcSocketState.discard(socket)
                }
            }
        }
        throw lastTransportError ?? HerdrClientError.invalidEnvelope
    }
}
