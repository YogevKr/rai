import RaiCore
import Foundation

struct CommandPaletteItem: Identifiable, Equatable {
    enum Destination: Equatable {
        case workspace(String)
        case tab(String)
        /// A repo with no space yet. Activating it creates one in that checkout.
        case newSpace(path: String, label: String)
        case command(PaletteCommand.Effect)
    }

    enum Kind: Equatable {
        case workspace
        case agent
        case repo
        case command
    }

    /// What Return does, once modifiers are taken into account.
    enum Action: Equatable {
        case open
        /// Open, then split a fresh tab in it.
        case newTab
        /// Branch off the row's checkout instead of opening it.
        case newWorktree
        case revealInFinder
    }

    let id: String
    let label: String
    /// Second line: the owning space for an agent, the path for a repo.
    let workspaceLabel: String
    let status: AgentStatus
    let destination: Destination
    let kind: Kind
    /// The row's checkout, when it has one. Searchable, so a query can name a
    /// directory instead of a label.
    var matchPath: String?

    var isWorkspace: Bool { kind == .workspace }

    var badge: String {
        switch kind {
        case .workspace: "SPACE"
        case .agent: "AGENT"
        case .repo: "OPEN"
        case .command: "RUN"
        }
    }

    var subtitle: String {
        switch kind {
        case .workspace: "Space · \(workspaceLabel)"
        case .agent, .repo, .command: workspaceLabel
        }
    }
}

extension CommandPaletteItem: PaletteRankable {
    var rankID: String { id }
    var rankStatus: AgentStatus { status }

    /// The title always outranks its supporting fields, so a title hit beats a
    /// path hit of the same shape. An agent's space matters more than its path,
    /// because people name the work by project far more often than by folder.
    var rankFields: [FuzzyField] {
        var fields = [FuzzyField(label)]
        if kind == .agent, !workspaceLabel.isEmpty {
            fields.append(FuzzyField(workspaceLabel, weight: 65))
        }
        if let matchPath, !matchPath.isEmpty {
            fields.append(FuzzyField(matchPath, weight: kind == .repo ? 65 : 45))
        }
        return fields
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
