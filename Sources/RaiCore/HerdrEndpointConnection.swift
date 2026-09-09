import Foundation

/// One generation-one endpoint session. Reconnect creates a new instance and never replays requests.
public actor HerdrEndpointConnection {
    public private(set) var welcome: HerdrEndpointWelcome?
    public private(set) var snapshot: HerdrEndpointSnapshot?
    public nonisolated let snapshots: AsyncThrowingStream<HerdrEndpointSnapshot, Error>
    public nonisolated let windowTitles: AsyncThrowingStream<String?, Error>
    private let titleUpdates: AsyncThrowingStream<String?, Error>.Continuation
    public nonisolated let notifications: AsyncThrowingStream<EndpointNotification, Error>
    private let notificationUpdates: AsyncThrowingStream<EndpointNotification, Error>.Continuation
    public nonisolated let surfaces: AsyncThrowingStream<HerdrEndpointSurface, Error>
    private let updates: AsyncThrowingStream<HerdrEndpointSnapshot, Error>.Continuation
    private let surfaceUpdates: AsyncThrowingStream<HerdrEndpointSurface, Error>.Continuation
    private var surface: HerdrEndpointSurface?
    private var graphics = EndpointGraphicsCache()
    private nonisolated let worker = EventWorkerState()
    private var socket: UnixSocket?
    private let writer = DispatchQueue(label: "rai.endpoint.writer")
    private var readerTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var startup: CheckedContinuation<HerdrEndpointSnapshot, Error>?
    private var pending: PendingRequest?
    private var started = false
    private var failure: Error?
    private var inputSelectionRevision: UInt64 = 0
    private var inputWrites: [UUID: (CheckedContinuation<Void, Error>, Task<Void, Never>)] = [:]

    private struct PendingRequest {
        let id: String
        let bootID: String
        let completion: CheckedContinuation<JSONValue, Error>
        var bytes = Data()
    }

    public init() {
        let channel = AsyncThrowingStream<HerdrEndpointSnapshot, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        snapshots = channel.stream
        updates = channel.continuation
        let titles = AsyncThrowingStream<String?, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        windowTitles = titles.stream
        titleUpdates = titles.continuation
        let notices = AsyncThrowingStream<EndpointNotification, Error>.makeStream(bufferingPolicy: .bufferingNewest(50))
        notifications = notices.stream
        notificationUpdates = notices.continuation
        let frames = AsyncThrowingStream<HerdrEndpointSurface, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        surfaces = frames.stream
        surfaceUpdates = frames.continuation
    }

    deinit {
        worker.stop()
        readerTask?.cancel()
        deadlineTask?.cancel()
        updates.finish()
        surfaceUpdates.finish()
        notificationUpdates.finish()
        titleUpdates.finish()
    }

    public nonisolated func disconnect() {
        worker.stop()
        Task { await fail(HerdrClientError.disconnected) }
    }

    public func resize(columns: UInt16, rows: UInt16, timeout: Duration = .seconds(10)) async throws {
        guard columns > 0, rows > 0 else { return }
        var frame = Data([12])
        for value in [UInt64(8), 16, UInt64(columns), UInt64(rows)] {
            HerdrEndpointWire.appendInteger(value, to: &frame)
        }
        frame.append(1) // Preserve the exact pixel-mouse capability advertised by EndpointHello.
        try await writeInputFrame(frame, timeout: timeout)
    }

    /// Raw committed text remains available for terminal applications. Paste uses its own semantic event.
    public func sendText(_ text: String, paneID: String, bootID: String, projectionRevision: UInt64, paste: Bool = false, timeout: Duration = .seconds(10)) async throws {
        try await sendInput(paste ? .paste(text) : .text(text), paneID: paneID, bootID: bootID, projectionRevision: projectionRevision, timeout: timeout)
    }

    public func sendInput(_ input: EndpointInput, paneID: String, bootID: String, projectionRevision: UInt64,
                          popupID: String? = nil, timeout: Duration = .seconds(10)) async throws {
        guard let snapshot, let surface, snapshot.bootID == bootID, surface.bootID == bootID,
              surface.popup?.terminalID == popupID,
              snapshot.focusedPaneID == paneID,
              projectionRevision >= inputSelectionRevision, projectionRevision <= snapshot.revision,
              surface.projectionRevision >= inputSelectionRevision, surface.projectionRevision <= snapshot.revision,
              surface.panes.contains(where: { $0.paneID == paneID }) else { throw HerdrEndpointError.staleIdentity }
        if case .mouse(let mouse) = input, !mouse.isValid { throw HerdrEndpointError.malformed }
        var frame = Data([popupID == nil ? 13 : 14])
        HerdrEndpointWire.appendString(popupID ?? paneID, to: &frame)
        frame.append(1) // One input event.
        input.encode(to: &frame)
        try await writeInputFrame(frame, timeout: timeout)
    }

    private func writeInputFrame(_ frame: Data, timeout: Duration) async throws {
        try Task.checkCancellation()
        if let failure { throw failure }
        guard frame.count <= HerdrEndpointWire.maximumFrameBytes, inputWrites.count < 64 else {
            throw HerdrEndpointError.limitExceeded
        }
        guard let socket, welcome != nil, !worker.isStopped else { throw HerdrClientError.disconnected }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let id = UUID()
                    let deadline = Task { [weak self] in
                        do { try await Task.sleep(for: timeout) } catch { return }
                        await self?.fail(HerdrEndpointError.timedOut)
                    }
                    inputWrites[id] = (continuation, deadline)
                    enqueue(frame, socket: socket) { [weak self] error in
                        Task { await self?.finishInput(id, error: error) }
                    }
                }
            } catch { fail(error); throw error }
        } onCancel: { self.disconnect() }
    }

    private func finishInput(_ id: UUID, error: Error?) {
        guard let (completion, deadline) = inputWrites.removeValue(forKey: id) else { return }
        deadline.cancel()
        if let error { completion.resume(throwing: error) }
        else { completion.resume() }
    }

    public func connect(socketPath: String, timeout: Duration = .seconds(10)) async throws -> HerdrEndpointSnapshot {
        guard !started else { throw HerdrEndpointError.busy }
        started = true
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let connection = try UnixSocket(path: socketPath)
                guard worker.install(connection) else { connection.close(); throw CancellationError() }
                socket = connection
                let encoder = JSONEncoder()
                encoder.keyEncodingStrategy = .convertToSnakeCase
                let hello = String(decoding: try encoder.encode(EndpointHello()), as: UTF8.self)
                let stream = Self.frames(from: connection)
                readerTask = Task { [weak self] in
                    do {
                        for try await message in stream { try await self?.receive(message) }
                        await self?.fail(HerdrClientError.disconnected)
                    } catch { await self?.fail(error) }
                }
                return try await withCheckedThrowingContinuation { continuation in
                    startup = continuation
                    armDeadline(timeout)
                    enqueue(HerdrEndpointWire.control(kind: "endpoint.hello.v1", data: hello), socket: connection) { [weak self] error in
                        if let error { Task { await self?.fail(error) } }
                    }
                }
            } catch {
                fail(error)
                throw error
            }
        } onCancel: { self.disconnect() }
    }

    public func readHistory(_ captured: EndpointTextRequest) async throws -> EndpointTextResult {
        try await EndpointHistoryReader.read(capture: { try await self.captureHistory(captured) }, send: { request in
            try await self.readHistorySelection(request)
        })
    }

    private func readHistorySelection(_ captured: EndpointTextRequest) async throws -> JSONValue {
        guard case .history(let start, let end, _, let revision, let truncated) = captured.action else {
            throw HerdrEndpointError.malformed
        }
        // Client viewport columns can differ from the shared PTY. Resolve its final text cell natively.
        let value = try await request(method: "pane.copy_motion", params: ["pane_id": .string(captured.paneID),
            "cursor": .object(["row": .number(Double(end)), "col": .number(0)]),
            "motion": .string("line_end"), "content_revision": .number(Double(revision))], expectedBootID: captured.bootID)
        guard let result = value.objectValue, result["type"]?.stringValue == "pane_copy_motion",
              result["pane_id"]?.stringValue == captured.paneID,
              let returnedRevision = result["content_revision"]?.numberValue, UInt64(exactly: returnedRevision) == revision,
              let cursor = result["cursor"]?.objectValue, cursor["row"]?.numberValue == Double(end),
              let number = cursor["col"]?.numberValue, let column = UInt16(exactly: number), column < UInt16.max else {
            throw HerdrEndpointError.malformed
        }
        let adjusted = EndpointTextRequest(id: captured.id, bootID: captured.bootID, paneID: captured.paneID,
            action: .history(startRow: start, endRow: end, endColumn: column, revision: revision, truncated: truncated))
        guard let rpc = adjusted.historyRPC else { throw HerdrEndpointError.malformed }
        return try await request(method: rpc.method, params: rpc.params, expectedBootID: captured.bootID)
    }

    private func captureHistory(_ captured: EndpointTextRequest) throws -> EndpointTextRequest {
        guard let snapshot else { throw HerdrEndpointError.staleIdentity }
        return try captured.refreshedHistory(snapshot: snapshot, surface: surface)
    }

    public func openPluginPane(_ invocation: EndpointPluginPaneInvocation) async throws -> JSONValue {
        guard let snapshot, invocation.projectionRevision >= inputSelectionRevision else { throw HerdrEndpointError.staleIdentity }
        try invocation.validate(in: snapshot)
        let rpc = try EndpointPluginOperation.openPane(invocation).rpc()
        return try await request(method: rpc.method, params: rpc.params, expectedBootID: invocation.bootID)
    }

    public func request(
        method: String, params: [String: JSONValue] = [:], expectedBootID: String,
        timeout: Duration = .seconds(10)
    ) async throws -> JSONValue {
        if let failure { throw failure }
        guard let welcome, let snapshot, let socket, !worker.isStopped else { throw HerdrClientError.disconnected }
        guard expectedBootID == snapshot.bootID else { throw HerdrEndpointError.staleIdentity }
        guard welcome.methods.contains(method) else { throw HerdrEndpointError.incompatible("Unsupported method \(method).") }
        guard pending == nil else { throw HerdrEndpointError.busy }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let id = UUID().uuidString
            let encoded = try JSONEncoder().encode(RPCRequest(id: id, method: method, params: params))
            let frame = HerdrEndpointWire.request(bootID: expectedBootID, json: String(decoding: encoded, as: UTF8.self))
            // Validate before installing a pending request. Writes have no retry path.
            guard frame.count <= HerdrEndpointWire.maximumFrameBytes else { throw HerdrEndpointError.limitExceeded }
            return try await withCheckedThrowingContinuation { continuation in
                pending = PendingRequest(id: id, bootID: expectedBootID, completion: continuation)
                armDeadline(timeout)
                enqueue(frame, socket: socket) { [weak self] error in
                    if let error { Task { await self?.fail(error) } }
                }
            }
        } onCancel: { self.disconnect() }
    }

    private func enqueue(_ frame: Data, socket: UnixSocket, completion: @escaping @Sendable (Error?) -> Void) {
        // One queue preserves frame boundaries while the actor remains available for deadlines and cancellation.
        writer.async {
            do { try socket.writeFrame(frame); completion(nil) }
            catch { completion(error) }
        }
    }

    private static func frames(from socket: UnixSocket) -> AsyncThrowingStream<HerdrEndpointWire.Message, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(32)) { continuation in
            continuation.onTermination = { _ in socket.close() }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    while true {
                        let message = try HerdrEndpointWire.decode(socket.readFrame())
                        switch continuation.yield(message) {
                        case .enqueued: break
                        case .dropped: throw HerdrEndpointError.limitExceeded
                        case .terminated: return
                        @unknown default: throw HerdrEndpointError.malformed
                        }
                    }
                } catch { continuation.finish(throwing: error) }
            }
        }
    }

    private func receive(_ message: HerdrEndpointWire.Message) throws {
        if failure != nil { return }
        switch message {
        case let .control(kind, data):
            switch kind {
            case "endpoint.welcome.v1":
                guard welcome == nil else { throw HerdrEndpointError.malformed }
                welcome = try JSONDecoder().decode(HerdrEndpointWelcome.self, from: Data(data.utf8))
            case "shell.snapshot.v1": try receiveSnapshot(Data(data.utf8))
            default: break // Unknown named controls are optional in generation one.
            }
        case let .response(bootID, requestID, final, data):
            try receiveResponse(bootID: bootID, requestID: requestID, final: final, data: data)
        case .windowTitle(let title):
            guard welcome != nil else { throw HerdrEndpointError.malformed }
            titleUpdates.yield(title)
        case .notification(let notification):
            guard welcome != nil || notification.kind == .error else { throw HerdrEndpointError.malformed }
            notificationUpdates.yield(notification)
        case .shutdown: throw HerdrClientError.disconnected
        case let .other(tag, payload):
            if tag == 13 { try receiveSurface(payload) }
            if tag == 19 {
                guard surface != nil else { throw HerdrEndpointError.staleIdentity }
                try surface?.applyPatch(payload)
                if let surface { surfaceUpdates.yield(surface) }
            }
        }
    }

    private func receiveSurface(_ data: Data) throws {
        var next = try HerdrEndpointSurface.decode(data)
        guard let snapshot, next.bootID == snapshot.bootID else { throw HerdrEndpointError.staleIdentity }
        if let surface, next.revision <= surface.revision { return }
        next.graphics = graphics.resolve(next.graphics)
        surface = next
        surfaceUpdates.yield(next)
    }

    private func receiveSnapshot(_ data: Data) throws {
        guard welcome != nil else { throw HerdrEndpointError.malformed }
        let next = try JSONDecoder().decode(HerdrEndpointSnapshot.self, from: data)
        if let snapshot {
            guard snapshot.bootID == next.bootID else { throw HerdrEndpointError.staleIdentity }
            guard next.revision > snapshot.revision else { return }
        }
        // Metadata revisions may advance while typed input waits for its turn.
        // Navigation ends the input lease, even when the view later returns to the same pane.
        if snapshot?.focusedPaneID != next.focusedPaneID || snapshot == nil {
            inputSelectionRevision = next.revision
        }
        snapshot = next
        updates.yield(next)
        if let startup {
            self.startup = nil
            deadlineTask?.cancel()
            startup.resume(returning: next)
        }
    }

    private func receiveResponse(bootID: String, requestID: String, final: Bool, data: Data) throws {
        guard var request = pending, request.id == requestID, request.bootID == bootID else {
            throw HerdrEndpointError.staleIdentity
        }
        guard request.bytes.count + data.count <= HerdrEndpointWire.maximumFrameBytes else {
            throw HerdrEndpointError.limitExceeded
        }
        request.bytes.append(data)
        pending = request
        guard final else { return }
        let envelope = try JSONDecoder().decode(RPCEnvelope.self, from: request.bytes)
        guard envelope.id == requestID else { throw HerdrEndpointError.malformed }
        guard envelope.result != nil || envelope.error != nil else { throw HerdrEndpointError.malformed }
        pending = nil
        deadlineTask?.cancel()
        if let error = envelope.error {
            request.completion.resume(throwing: HerdrClientError.remote(code: error.code, message: error.message))
        } else if let result = envelope.result {
            request.completion.resume(returning: result)
        }
    }

    private func armDeadline(_ timeout: Duration) {
        deadlineTask?.cancel()
        deadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            await self?.fail(HerdrEndpointError.timedOut)
        }
    }

    private func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        worker.stop()
        socket = nil
        deadlineTask?.cancel()
        startup?.resume(throwing: error)
        startup = nil
        pending?.completion.resume(throwing: error)
        pending = nil
        for (completion, deadline) in inputWrites.values {
            deadline.cancel()
            completion.resume(throwing: error)
        }
        inputWrites.removeAll()
        updates.finish(throwing: error)
        surfaceUpdates.finish(throwing: error)
        notificationUpdates.finish(throwing: error)
        titleUpdates.yield(nil)
        titleUpdates.finish(throwing: error)
    }
}
