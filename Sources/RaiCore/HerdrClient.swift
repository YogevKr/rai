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

struct RPCRequest: Encodable {
    let id: String
    let method: String
    let params: [String: JSONValue]
}

struct RPCErrorBody: Decodable {
    let code: String
    let message: String
}

struct RPCEnvelope: Decodable {
    let id: String?
    let result: JSONValue?
    let error: RPCErrorBody?
    let event: JSONValue?
    let data: [String: JSONValue]?
}

final class EventWorkerState: @unchecked Sendable {
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

    /// Protocol 1 supports workspace.closed; protocol 14 adds renamed and 19 adds reordered.
    /// Verified against Herdr v0.5.0 src/api/schema.rs and src/server/protocol.rs.
    /// Both changes can occur without focus or layout events. Unknown protocols
    /// use the baseline until the acknowledged snapshot selects supported types.
    /// Older servers reject unknown types and close the entire event stream.
    public static func subscriptions(forProtocol protocolVersion: Int?) -> [String] {
        var subscriptions = defaultSubscriptions
        if let protocolVersion, protocolVersion >= 1 { subscriptions.append("workspace.closed") }
        if let protocolVersion, protocolVersion >= 14 { subscriptions.append("workspace.renamed") }
        if let protocolVersion, protocolVersion >= 19 { subscriptions.append("workspace.reordered") }
        return subscriptions
    }

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
        let result: SnapshotResult = try call(
            method: "session.snapshot", params: [:], retryOnTransportFailure: true
        )
        return result.snapshot
    }

    public nonisolated func explainAgent(_ paneID: String, timeout: Duration = .seconds(10)) async throws -> String {
        let reader = HerdrClient(socketPath: socketPath)
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await reader.readAgentExplanation(paneID) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw HerdrClientError.remote(code: "request_timed_out", message: "The agent explanation request timed out. Try again.")
                }
                defer {
                    // Closing before the group drains also unblocks a stalled read.
                    reader.disconnect()
                    group.cancelAll()
                }
                guard let result = try await group.next() else { throw CancellationError() }
                return result
            }
        } onCancel: { reader.disconnect() }
    }

    private func readAgentExplanation(_ paneID: String) throws -> String {
        let result: JSONValue = try call(method: "agent.explain", params: ["target": .string(paneID)])
        let output = JSONEncoder()
        output.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try output.encode(result), as: UTF8.self)
    }

    public func serverInfo() async throws -> HerdrServerInfo {
        try call(method: "ping", params: [:], retryOnTransportFailure: true)
    }

    public nonisolated func paneGraphicsEnabled(paneID: String, timeout: Duration = .seconds(5)) async throws -> Bool {
        do {
            _ = try await boundedRequest(timeout: timeout) { reader in
                try await reader.call(method: "pane.graphics.info", params: ["pane_id": .string(paneID)])
            }
            return true
        } catch HerdrClientError.remote(let code, let message) {
            if code == "feature_disabled" { return false }
            if code == "cell_size_unavailable" { return true }
            throw HerdrClientError.remote(code: code, message: message)
        }
    }

    public nonisolated func pluginOperation(_ operation: EndpointPluginOperation,
                                           timeout: Duration = .seconds(10)) async throws -> JSONValue {
        let rpc = try operation.rpc()
        guard rpc.method.hasPrefix("plugin.") || rpc.method.hasPrefix("agent.view.") else {
            throw HerdrEndpointError.incompatible("This operation must use the active endpoint view.")
        }
        return try await boundedRequest(timeout: timeout) { client in
            try await client.pluginRequest(method: rpc.method, params: rpc.params)
        }
    }

    private func pluginRequest(method: String, params: [String: JSONValue]) throws -> JSONValue {
        try call(method: method, params: params, maximumResponseBytes: HerdrEndpointWire.maximumFrameBytes)
    }

    public nonisolated func agentPrompt(paneID: String, text: String, timeout: Duration = .seconds(30)) async throws -> JSONValue {
        guard !text.isEmpty, text.utf8.count <= EndpointTextRequest.maximumTextBytes, !text.contains("\0") else {
            throw HerdrEndpointError.limitExceeded
        }
        return try await boundedRequest(timeout: timeout) { client in
            try await client.submitAgentPrompt(paneID: paneID, text: text)
        }
    }

    private nonisolated func boundedRequest(timeout: Duration,
        operation: @escaping @Sendable (HerdrClient) async throws -> JSONValue) async throws -> JSONValue {
        let reader = HerdrClient(socketPath: socketPath)
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: JSONValue.self) { group in
                group.addTask { try await operation(reader) }
                group.addTask { try await Task.sleep(for: timeout); throw URLError(.timedOut) }
                defer { reader.disconnect(); group.cancelAll() }
                guard let value = try await group.next() else { throw CancellationError() }
                return value
            }
        } onCancel: { reader.disconnect() }
    }

    private func submitAgentPrompt(paneID: String, text: String) throws -> JSONValue {
        // AgentPrompt owns multiline paste and submission. Ambiguous writes never retry.
        try call(method: "agent.prompt", params: ["target": .string(paneID), "text": .string(text)],
                 maximumResponseBytes: HerdrEndpointWire.maximumFrameBytes)
    }

    public func closeWorkspace(_ workspaceID: String, closeGroup: Bool = false) async throws {
        let _: JSONValue = try call(method: "workspace.close", params: [
            "workspace_id": .string(workspaceID), "close_group": .bool(closeGroup)
        ])
    }

    public func readPane(
        paneID: String,
        source: String = "visible",
        lines: Int? = nil,
        format: String = "ansi",
        stripANSI: Bool = false
    ) async throws -> PaneRead {
        var params: [String: JSONValue] = [
            "pane_id": .string(paneID),
            "source": .string(source),
            "format": .string(format),
            "strip_ansi": .bool(stripANSI),
        ]
        if let lines {
            params["lines"] = .number(Double(lines))
        }
        let result: PaneReadResult = try call(
            method: "pane.read", params: params, retryOnTransportFailure: true
        )
        return result.read
    }

    public func sendKeys(paneID: String, keys: [String]) async throws {
        let _: JSONValue = try call(
            method: "pane.send_input",
            params: [
                "pane_id": .string(paneID),
                "keys": .array(keys.map { .string($0) }),
            ]
        )
    }

    public func sendInput(paneID: String, bytes: [UInt8],
                          endpointIdentity: (socketPath: String, bootID: String)? = nil,
                          validateBeforeSend: @escaping @Sendable () async throws -> Void = {}) async throws {
        let tokens = PaneInputTokenizer.tokenize(bytes)
        var previousWasText = false
        for token in tokens {
            let params: [String: JSONValue]
            switch token {
            case let .text(text):
                params = ["pane_id": .string(paneID), "text": .string(text)]
                previousWasText = true
            case let .keys(keys):
                // "message⏎" arrives as one burst. Let the pasted text settle
                // before the submit keypress: agent TUIs treat a same-instant
                // enter as part of the paste and insert a newline instead of
                // submitting.
                if previousWasText, keys.first == "enter" {
                    try await Task.sleep(nanoseconds: 300_000_000)
                }
                params = ["pane_id": .string(paneID), "keys": .array(keys.map { .string($0) })]
                previousWasText = false
            }
            try Task.checkCancellation()
            try await validateBeforeSend()
            if let endpointIdentity {
                // Pin each token before checking the captured boot. Never reopen a dispatched write.
                let pinned = HerdrPinnedRPC()
                _ = try await pinned.request(socketPath: socketPath,
                    endpointSocketPath: endpointIdentity.socketPath, bootID: endpointIdentity.bootID,
                    method: "pane.send_input", params: params, validate: { snapshot in
                        guard snapshot.panes.contains(where: { $0.objectValue?["pane_id"]?.stringValue == paneID }) else {
                            throw HerdrEndpointError.staleIdentity
                        }
                    })
            } else {
                let _: JSONValue = try call(method: "pane.send_input", params: params)
            }
        }
    }

    public func focusPane(_ paneID: String) async throws {
        let _: JSONValue = try call(
            method: "pane.focus",
            params: ["pane_id": .string(paneID)]
        )
    }

    /// Direct scrollback control (protocol 22). Never retry a dispatched write.
    public func scrollPane(_ paneID: String, offsetFromBottom: Int) async throws {
        try Task.checkCancellation()
        let _: JSONValue = try call(
            method: "pane.scroll",
            params: [
                "pane_id": .string(paneID),
                "offset_from_bottom": .number(Double(max(0, offsetFromBottom))),
            ],
            retryOnTransportFailure: false
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

    /// pane.move silently no-ops (changed: false, reason: zoomed_tab) when the
    /// pane's tab is zoomed — un-zoom before moving panes out of a zoomed tab.
    public func unzoomPane(_ paneID: String) throws {
        let _: JSONValue = try call(
            method: "pane.zoom",
            params: [
                "pane_id": .string(paneID),
                "mode": .string("off"),
            ]
        )
    }

    @discardableResult
    public func movePane(
        _ paneID: String,
        to destination: PaneMoveDestination,
        focus: Bool = false
    ) throws -> PaneMoveOutcome {
        let result: PaneMoveResult = try call(
            method: "pane.move",
            params: [
                "pane_id": .string(paneID),
                "destination": destination.jsonValue,
                "focus": .bool(focus),
            ]
        )
        return result.moveResult
    }

    public nonisolated func events(
        subscriptions: [String] = HerdrClient.defaultSubscriptions,
        paneIDs: [String] = []
    ) -> AsyncThrowingStream<HerdrEvent, Error> {
        let subscription = subscribe(subscriptions: subscriptions, paneIDs: paneIDs)
        return AsyncThrowingStream { continuation in
            let task = Task {
                defer { subscription.close() }
                do {
                    for try await message in subscription.messages {
                        if case .event(let event) = message { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                subscription.close()
            }
        }
    }

    /// Wait for `ready` before loading a snapshot. The stream buffers later events.
    public nonisolated func subscribe(
        subscriptions: [String] = HerdrClient.defaultSubscriptions,
        paneIDs: [String] = []
    ) -> HerdrEventSubscription {
        let path = socketPath
        let state = EventWorkerState()
        var wireSubscriptions: [JSONValue] = []
        for type in subscriptions {
            switch type {
            case "pane.agent_status_changed", "pane.scroll_changed":
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
        let (messages, continuation) = AsyncThrowingStream<HerdrEventMessage, Error>.makeStream()
        // A dedicated thread, NOT Task.detached: the read below blocks in
        // read(2) for the stream's whole life, and the cooperative pool is
        // capped at the core count. One stream per pane parked there
        // starves every other async task in the app.
        let worker = Thread {
            do {
                let socket = try UnixSocket(path: path)
                defer { socket.close() }
                guard state.install(socket) else { return }
                let request = RPCRequest(
                    id: "sub",
                    method: "events.subscribe",
                    params: [
                        "subscriptions": .array(subscriptionsPayload),
                    ]
                )
                try socket.writeLine(JSONEncoder().encode(request))
                var acknowledged = false
                while !state.isStopped {
                    let line = try socket.readLine()
                    let envelope = try JSONDecoder().decode(RPCEnvelope.self, from: line)
                    if let error = envelope.error {
                        throw HerdrClientError.remote(
                            code: error.code,
                            message: error.message
                        )
                    }
                    if !acknowledged {
                        guard envelope.id == "sub",
                              case .object(let result) = envelope.result,
                              result["type"]?.stringValue == "subscription_started" else {
                            throw HerdrClientError.invalidEnvelope
                        }
                        acknowledged = true
                        continuation.yield(.ready)
                        continue
                    }
                    guard let rawEvent = envelope.event else {
                        throw HerdrClientError.invalidEvent
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
                    continuation.yield(.event(event))
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
        worker.name = "rai.herdr-events"
        worker.start()
        continuation.onTermination = { _ in
            // Closing the socket fails the blocked read; the thread exits.
            state.stop()
        }
        return HerdrEventSubscription(messages: messages) {
            state.stop()
            continuation.finish()
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
        params: [String: JSONValue],
        retryOnTransportFailure: Bool = false,
        maximumResponseBytes: Int? = nil
    ) throws -> T {
        try Task.checkCancellation()
        let id = String(nextID)
        nextID += 1
        let request = try encoder.encode(RPCRequest(id: id, method: method, params: params))

        // A non-retryable write needs a fresh socket: Herdr may close the
        // preceding request's connection after delivering its response.
        if !retryOnTransportFailure, let socket = rpcSocketState.current {
            rpcSocketState.discard(socket)
        }

        var lastTransportError: Error?
        for _ in 0..<(retryOnTransportFailure ? 2 : 1) {
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
                    let line = try socket.readLine(maximumBytes: maximumResponseBytes)
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
