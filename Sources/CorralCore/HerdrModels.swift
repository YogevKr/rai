import Foundation

public enum AgentStatus: String, Codable, Sendable, CaseIterable {
    case working
    case blocked
    case done
    case idle
    case unknown
}

public struct Workspace: Codable, Identifiable, Sendable, Equatable {
    public let workspaceID: String
    public let number: Int
    public let label: String
    public let focused: Bool
    public let paneCount: Int
    public let tabCount: Int
    public let activeTabID: String
    public let agentStatus: AgentStatus
    public let worktree: WorkspaceWorktree?

    public var id: String { workspaceID }

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case number, label, focused
        case paneCount = "pane_count"
        case tabCount = "tab_count"
        case activeTabID = "active_tab_id"
        case agentStatus = "agent_status"
        case worktree
    }
}

public struct WorkspaceWorktree: Codable, Sendable, Equatable {
    public let repoName: String
    public let checkoutPath: String
    public let isLinkedWorktree: Bool

    enum CodingKeys: String, CodingKey {
        case repoName = "repo_name"
        case checkoutPath = "checkout_path"
        case isLinkedWorktree = "is_linked_worktree"
    }
}

public struct HerdrTab: Codable, Identifiable, Sendable, Equatable {
    public let tabID: String
    public let workspaceID: String
    public let number: Int
    public let label: String
    public let focused: Bool
    public let paneCount: Int
    public let agentStatus: AgentStatus

    public var id: String { tabID }

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
        case workspaceID = "workspace_id"
        case number, label, focused
        case paneCount = "pane_count"
        case agentStatus = "agent_status"
    }
}

public struct Pane: Codable, Identifiable, Sendable, Equatable {
    public let paneID: String
    public let terminalID: String
    public let workspaceID: String
    public let tabID: String
    public let focused: Bool
    public let cwd: String
    public let foregroundCWD: String?
    public let agent: String?
    public let terminalTitle: String?
    public let terminalTitleStripped: String?
    public let agentStatus: AgentStatus
    public let revision: UInt64

    public var id: String { paneID }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case terminalID = "terminal_id"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case focused, cwd, agent, revision
        case foregroundCWD = "foreground_cwd"
        case terminalTitle = "terminal_title"
        case terminalTitleStripped = "terminal_title_stripped"
        case agentStatus = "agent_status"
    }
}

public struct SessionSnapshot: Codable, Sendable, Equatable {
    public let version: String
    public let `protocol`: Int
    public let focusedWorkspaceID: String?
    public let focusedTabID: String?
    public let focusedPaneID: String?
    public let workspaces: [Workspace]
    public let tabs: [HerdrTab]
    public let panes: [Pane]
    public let layouts: [PaneLayoutSnapshot]

    enum CodingKeys: String, CodingKey {
        case version, `protocol`, workspaces, tabs, panes, layouts
        case focusedWorkspaceID = "focused_workspace_id"
        case focusedTabID = "focused_tab_id"
        case focusedPaneID = "focused_pane_id"
    }
}

public struct PaneLayoutRect: Codable, Hashable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public func contains(_ other: PaneLayoutRect) -> Bool {
        other.x >= x
            && other.y >= y
            && other.x + other.width <= x + width
            && other.y + other.height <= y + height
    }
}

public struct PaneLayoutPane: Codable, Sendable, Equatable {
    public let paneID: String
    public let focused: Bool
    public let rect: PaneLayoutRect

    public init(paneID: String, focused: Bool, rect: PaneLayoutRect) {
        self.paneID = paneID
        self.focused = focused
        self.rect = rect
    }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case focused, rect
    }
}

public enum SplitDirection: String, Codable, Sendable {
    case right
    case down
}

public struct PaneLayoutSplit: Codable, Sendable, Equatable {
    public let id: String
    public let direction: SplitDirection
    public let ratio: Double
    public let rect: PaneLayoutRect

    public init(
        id: String,
        direction: SplitDirection,
        ratio: Double,
        rect: PaneLayoutRect
    ) {
        self.id = id
        self.direction = direction
        self.ratio = ratio
        self.rect = rect
    }
}

public struct PaneLayoutSnapshot: Codable, Sendable, Equatable {
    public let workspaceID: String
    public let tabID: String
    public let zoomed: Bool
    public let area: PaneLayoutRect
    public let focusedPaneID: String
    public let panes: [PaneLayoutPane]
    public let splits: [PaneLayoutSplit]

    public init(
        workspaceID: String,
        tabID: String,
        zoomed: Bool,
        area: PaneLayoutRect,
        focusedPaneID: String,
        panes: [PaneLayoutPane],
        splits: [PaneLayoutSplit]
    ) {
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.zoomed = zoomed
        self.area = area
        self.focusedPaneID = focusedPaneID
        self.panes = panes
        self.splits = splits
    }

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case zoomed, area
        case focusedPaneID = "focused_pane_id"
        case panes, splits
    }
}

struct SnapshotResult: Codable {
    let snapshot: SessionSnapshot
}

public struct PaneRead: Codable, Sendable {
    public let paneID: String
    public let text: String
    public let revision: UInt64
    public let truncated: Bool

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case text, revision, truncated
    }
}

struct PaneReadResult: Codable {
    let read: PaneRead
}

public struct HerdrEvent: Sendable, Equatable {
    public let name: String
    public let data: [String: JSONValue]

    public var paneID: String? { data["pane_id"]?.stringValue }
    public var workspaceID: String? { data["workspace_id"]?.stringValue }
    public var tabID: String? { data["tab_id"]?.stringValue }
}
