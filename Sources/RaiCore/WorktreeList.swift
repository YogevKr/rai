import Foundation

public struct HerdrWorktree: Codable, Identifiable, Sendable, Equatable {
    public let path: String
    public let branch: String?
    public let isBare: Bool
    public let isDetached: Bool
    public let isPrunable: Bool
    public let isLinkedWorktree: Bool
    public let label: String
    public let openWorkspaceID: String?

    public var id: String { path }

    enum CodingKeys: String, CodingKey {
        case path, branch, label
        case isBare = "is_bare"
        case isDetached = "is_detached"
        case isPrunable = "is_prunable"
        case isLinkedWorktree = "is_linked_worktree"
        case openWorkspaceID = "open_workspace_id"
    }
}

public enum WorktreeListParser {
    public enum ParseError: Error, Equatable {
        case unexpectedResultType(String)
    }

    public static func parse(_ json: String) throws -> [HerdrWorktree] {
        let data = Data(json.utf8)
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.result.type == "worktree_list" else {
            throw ParseError.unexpectedResultType(envelope.result.type)
        }
        return envelope.result.worktrees
    }

    private struct Envelope: Decodable {
        let result: Result
    }

    private struct Result: Decodable {
        let type: String
        let worktrees: [HerdrWorktree]
    }
}
