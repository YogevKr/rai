import CorralCore
import Foundation

struct CommandPaletteItem: Identifiable, Equatable {
    enum Destination: Equatable {
        case workspace(String)
        case tab(String)
    }

    let id: String
    let label: String
    let workspaceLabel: String
    let status: AgentStatus
    let destination: Destination
    let isWorkspace: Bool
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

struct StatusExplanation: Identifiable, Equatable {
    let id: UUID
    let title: String
    let text: String?

    var isLoading: Bool { text == nil }
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
