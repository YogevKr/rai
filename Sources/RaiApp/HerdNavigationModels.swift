import RaiCore
import Foundation

struct CommandPaletteItem: Identifiable, Equatable {
    enum Destination: Equatable {
        case workspace(String)
        case tab(String)
        /// A repo with no space yet. Activating it creates one in that checkout.
        case newSpace(path: String, label: String)
    }

    enum Kind: Equatable {
        case workspace
        case agent
        case repo
    }

    let id: String
    let label: String
    /// Second line: the owning space for an agent, the path for a repo.
    let workspaceLabel: String
    let status: AgentStatus
    let destination: Destination
    let kind: Kind

    var isWorkspace: Bool { kind == .workspace }

    var badge: String {
        switch kind {
        case .workspace: "SPACE"
        case .agent: "AGENT"
        case .repo: "OPEN"
        }
    }

    var subtitle: String {
        switch kind {
        case .workspace: "Space · \(workspaceLabel)"
        case .agent, .repo: workspaceLabel
        }
    }
}

struct RenameRequest: Identifiable, Equatable {
    enum Target: Equatable {
        case workspace(String)
        case tab(String)
    }

    let id = UUID()
    let target: Target
    let title: String
    let initialLabel: String
}

// Which sidebar row is being renamed in place (vs. the modal RenameRequest).
enum InlineRenameTarget: Equatable {
    case workspace(String)
    case tab(String)
}

struct StatusExplanation: Identifiable, Equatable {
    let id: UUID
    let title: String
    let text: String?

    var isLoading: Bool { text == nil }
}

struct PluginAction: Identifiable, Equatable {
    enum Context: String, Decodable {
        case workspace
        case tab
        case pane
    }

    let id: String
    let title: String
    let description: String?
    let pluginId: String
    let contexts: Set<Context>
}

struct WorktreeRepositoryContext: Equatable {
    let repoName: String
    let checkoutPath: String
}

struct WorktreeCreateRequest: Identifiable, Equatable {
    let id = UUID()
    let context: WorktreeRepositoryContext
}

struct WorktreeOpenRequest: Identifiable, Equatable {
    let id: UUID
    let context: WorktreeRepositoryContext
    var worktrees: [HerdrWorktree]
    var isLoading: Bool
    var error: String?

    init(context: WorktreeRepositoryContext) {
        id = UUID()
        self.context = context
        worktrees = []
        isLoading = true
        error = nil
    }
}

struct WorktreeAlert: Identifiable, Equatable {
    enum Kind: Equatable {
        case confirmRemoval(Workspace)
        case confirmForcedRemoval(Workspace)
        case error(title: String, message: String)
    }

    let id = UUID()
    let kind: Kind
}

struct NewSessionRequest: Identifiable {
    let id = UUID()
}

struct RemoteHerdRequest: Identifiable {
    let id = UUID()
}

struct SessionAlert: Identifiable {
    enum Kind {
        case confirmStop(HerdrSession, isCurrent: Bool)
        case error(title: String, message: String)
    }

    let id = UUID()
    let kind: Kind
}
