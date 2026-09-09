import Foundation

public enum EndpointWorktreeOperation: Codable, Equatable, Sendable {
    case list(workspaceID: String, trust: Bool)
    case create(workspaceID: String, branch: String, base: String, path: String, label: String, trust: Bool)
    case open(workspaceID: String, path: String, trust: Bool)
    case remove(workspaceID: String, force: Bool, trust: Bool)

    public var rpc: (method: String, params: [String: JSONValue]) {
        switch self {
        case .list(let workspace, let trust):
            return ("worktree.list", ["workspace_id": .string(workspace), "trust_repository": .bool(trust)])
        case .create(let workspace, let branch, let base, let path, let label, let trust):
            var params: [String: JSONValue] = ["workspace_id": .string(workspace), "branch": .string(branch),
                "focus": .bool(true), "trust_repository": .bool(trust)]
            for (key, value) in [("base", base), ("path", path), ("label", label)] where !value.isEmpty { params[key] = .string(value) }
            return ("worktree.create", params)
        case .open(let workspace, let path, let trust):
            return ("worktree.open", ["workspace_id": .string(workspace), "path": .string(path),
                "focus": .bool(true), "trust_repository": .bool(trust)])
        case .remove(let workspace, let force, let trust):
            return ("worktree.remove", ["workspace_id": .string(workspace), "force": .bool(force), "trust_repository": .bool(trust)])
        }
    }
}

public struct EndpointWorktreeRequest: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let bootID: String
    public let operation: EndpointWorktreeOperation

    public init(id: UUID = UUID(), bootID: String, operation: EndpointWorktreeOperation) {
        self.id = id; self.bootID = bootID; self.operation = operation
    }

    public func validate(in snapshot: HerdrEndpointSnapshot) throws {
        let rpc = operation.rpc
        guard bootID == snapshot.bootID, let workspaceID = rpc.params["workspace_id"]?.stringValue,
              let workspace = snapshot.workspaces.first(where: { $0.objectValue?["workspace_id"]?.stringValue == workspaceID }) else {
            throw HerdrEndpointError.staleIdentity
        }
        for value in rpc.params.values.compactMap(\.stringValue) {
            guard value.utf8.count <= 4096, !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
                throw HerdrEndpointError.limitExceeded
            }
        }
        if case .create(_, let branch, _, let path, _, _) = operation {
            guard !branch.trimmingCharacters(in: .whitespaces).isEmpty, path.isEmpty || path.hasPrefix("/") else {
                throw HerdrEndpointError.malformed
            }
        }
        if case .open(_, let path, _) = operation, !path.hasPrefix("/") { throw HerdrEndpointError.malformed }
        if case .remove = operation {
            guard workspace.objectValue?["worktree"]?.objectValue?["is_linked_worktree"] == .bool(true) else {
                throw HerdrEndpointError.staleIdentity
            }
        }
    }
}

public struct EndpointWorktreeResult: Codable, Equatable, Sendable {
    public let request: EndpointWorktreeRequest
    public let worktrees: [HerdrWorktree]
    public let error: String?
    public let navigationPaneID: String?

    public init(request: EndpointWorktreeRequest, result: JSONValue) throws {
        self.request = request
        navigationPaneID = try Self.navigationPane(in: result, operation: request.operation)
        if case .list = request.operation {
            let envelope = JSONValue.object(["result": result])
            worktrees = try WorktreeListParser.parse(String(decoding: JSONEncoder().encode(envelope), as: UTF8.self))
        } else { worktrees = [] }
        error = nil
    }

    public init(request: EndpointWorktreeRequest, error: String) {
        self.request = request; self.worktrees = []; self.error = error; navigationPaneID = nil
    }

    private static func navigationPane(in result: JSONValue, operation: EndpointWorktreeOperation) throws -> String? {
        let expected: String
        switch operation {
        case .create: expected = "worktree_created"
        case .open: expected = "worktree_opened"
        default: return nil
        }
        guard result.objectValue?["type"]?.stringValue == expected,
              let pane = result.objectValue?["root_pane"]?.objectValue,
              let id = pane["pane_id"]?.stringValue, !id.isEmpty,
              let workspace = result.objectValue?["workspace"]?.objectValue?["workspace_id"]?.stringValue,
              !workspace.isEmpty, pane["workspace_id"]?.stringValue == workspace else {
            throw HerdrEndpointError.malformed
        }
        return id
    }
}
