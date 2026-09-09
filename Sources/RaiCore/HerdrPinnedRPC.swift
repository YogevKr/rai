import Foundation

/// Pin the API connection before validation. Never reconnect a mutation.
public final class HerdrPinnedRPC: @unchecked Sendable {
    private let worker = EventWorkerState()
    private let legacyReader = EventWorkerState()
    private let verifier = HerdrEndpointConnection()
    public init() {}
    public func cancel() { worker.stop(); legacyReader.stop(); verifier.disconnect() }
    deinit { cancel() }

    public func request(socketPath: String, endpointSocketPath: String, bootID: String,
                        method: String, params: [String: JSONValue], timeout: Duration = .seconds(30),
                        validate: @escaping @Sendable (HerdrEndpointSnapshot) throws -> Void) async throws -> JSONValue {
        try await validatedRequest(socketPath: socketPath, method: method, params: params, timeout: timeout) {
            let snapshot = try await self.verifier.connect(socketPath: endpointSocketPath)
            guard snapshot.bootID == bootID else { throw HerdrEndpointError.staleIdentity }
            try validate(snapshot)
        }
    }

    private func validatedRequest(socketPath: String, method: String, params: [String: JSONValue], timeout: Duration,
        validate: @escaping @Sendable () async throws -> Void) async throws -> JSONValue {
        try await withTaskCancellationHandler {
            defer { cancel() }
            return try await withThrowingTaskGroup(of: JSONValue.self) { group in
                group.addTask {
                    try Task.checkCancellation()
                    let socket = try UnixSocket(path: socketPath)
                    guard self.worker.install(socket) else { socket.close(); throw CancellationError() }
                    try await validate()
                    try Task.checkCancellation()
                    return try await Self.exchange(on: socket, method: method, params: params)
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw HerdrEndpointError.timedOut
                }
                // Close blocked readers before the task group drains its children.
                defer { self.cancel(); group.cancelAll() }
                guard let result = try await group.next() else { throw HerdrEndpointError.malformed }
                return result
            }
        } onCancel: { self.cancel() }
    }

    private static func exchange(on socket: UnixSocket, method: String, params: [String: JSONValue]) async throws -> JSONValue {
        let request = RPCRequest(id: UUID().uuidString, method: method, params: params)
        let data = try JSONEncoder().encode(request)
        guard data.count <= 1_048_576 else { throw HerdrEndpointError.limitExceeded }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try socket.writeLine(data)
                    let response = try JSONDecoder().decode(RPCEnvelope.self, from: socket.readLine(maximumBytes: 2_097_152))
                    guard response.id == request.id else { throw HerdrClientError.invalidEnvelope }
                    if let error = response.error { throw HerdrClientError.remote(code: error.code, message: error.message) }
                    guard let result = response.result else { throw HerdrClientError.invalidEnvelope }
                    continuation.resume(returning: result)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

extension HerdrPinnedRPC {
    /// Legacy servers have no boot identity. Validate reviewed metadata on a fresh
    /// reader, but keep the mutation on the socket opened before that validation.
    public func closeReviewedLegacyWorkspace(socketPath: String, preview: WorkspaceClosePreview,
        connectionID: String, timeout: Duration = .seconds(30),
        validateConnection: @escaping @Sendable () async throws -> Void) async throws {
        _ = try await validatedRequest(socketPath: socketPath, method: "workspace.close",
            params: ["workspace_id": .string(preview.workspaceID), "close_group": .bool(false)], timeout: timeout) {
            let reader = try UnixSocket(path: socketPath)
            guard self.legacyReader.install(reader) else { reader.close(); throw CancellationError() }
            let value = try await Self.exchange(on: reader, method: "session.snapshot", params: [:])
            let current = try JSONDecoder().decode(SnapshotResult.self, from: JSONEncoder().encode(value)).snapshot
            guard current.protocol > 0, current.protocol < 22 else { throw HerdrEndpointError.staleIdentity }
            try preview.validate(against: current, connectionID: connectionID)
            for reviewed in preview.workspaces {
                let matches = current.workspaces.filter { $0.workspaceID == reviewed.workspaceID }
                guard matches.count == 1, matches[0].worktree == reviewed.worktree else {
                    throw HerdrEndpointError.staleIdentity
                }
            }
            try await validateConnection()
        }
    }
}
