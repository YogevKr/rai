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
