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

/// Scrollback position of a pane, straight from herdr's snapshot: how far the
/// viewport sits above the live bottom, and how far it can go.
public struct PaneScroll: Codable, Sendable, Equatable {
    public let offsetFromBottom: Int
    public let maxOffsetFromBottom: Int
    public let viewportRows: Int

    public init(offsetFromBottom: Int, maxOffsetFromBottom: Int, viewportRows: Int) {
        self.offsetFromBottom = offsetFromBottom
        self.maxOffsetFromBottom = maxOffsetFromBottom
        self.viewportRows = viewportRows
    }

    enum CodingKeys: String, CodingKey {
        case offsetFromBottom = "offset_from_bottom"
        case maxOffsetFromBottom = "max_offset_from_bottom"
        case viewportRows = "viewport_rows"
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
    public let scroll: PaneScroll?

    public var id: String { paneID }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case terminalID = "terminal_id"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case focused, cwd, agent, revision, scroll
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

/// Where pane.move puts a pane (protocol 16). `tab.move` can only reorder
/// within a workspace, so relocating a whole tab across spaces is built from
/// these: lead pane → `newTab`/`newWorkspace`, remaining panes → `tab`.
public enum PaneMoveDestination: Sendable, Equatable {
    case tab(tabID: String, split: SplitDirection, targetPaneID: String? = nil)
    case newTab(workspaceID: String?, label: String?)
    case newWorkspace(label: String?, tabLabel: String?)

    public var jsonValue: JSONValue {
        switch self {
        case let .tab(tabID, split, targetPaneID):
            var object: [String: JSONValue] = [
                "type": .string("tab"),
                "tab_id": .string(tabID),
                "split": .string(split.rawValue),
            ]
            if let targetPaneID {
                object["target_pane_id"] = .string(targetPaneID)
            }
            return .object(object)
        case let .newTab(workspaceID, label):
            var object: [String: JSONValue] = ["type": .string("new_tab")]
            if let workspaceID {
                object["workspace_id"] = .string(workspaceID)
            }
            if let label {
                object["label"] = .string(label)
            }
            return .object(object)
        case let .newWorkspace(label, tabLabel):
            var object: [String: JSONValue] = ["type": .string("new_workspace")]
            if let label {
                object["label"] = .string(label)
            }
            if let tabLabel {
                object["tab_label"] = .string(tabLabel)
            }
            return .object(object)
        }
    }
}

/// The slice of pane.move's result the app acts on. `createdTab` is the tab a
/// `newTab`/`newWorkspace` destination made — the anchor for moving a
/// multi-pane tab's remaining panes. `pane` is the moved pane AFTER the move:
/// crossing workspaces rewrites pane ids (w1:p2 → w2:p5), so selection must
/// follow this id, not the one the request was made with.
public struct PaneMoveOutcome: Codable, Sendable {
    public let changed: Bool
    public let pane: Pane
    public let createdTab: HerdrTab?
    public let closedTabID: String?
    public let closedWorkspaceID: String?

    enum CodingKeys: String, CodingKey {
        case changed, pane
        case createdTab = "created_tab"
        case closedTabID = "closed_tab_id"
        case closedWorkspaceID = "closed_workspace_id"
    }
}

// pane.move's wire result wraps the payload:
// {"type": "pane_move", "move_result": {...}}.
struct PaneMoveResult: Codable {
    let moveResult: PaneMoveOutcome

    enum CodingKeys: String, CodingKey {
        case moveResult = "move_result"
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

    /// The scroll payload of a pane.scroll_changed event.
    public var scroll: PaneScroll? {
        guard let object = data["scroll"]?.objectValue,
              let offset = object["offset_from_bottom"]?.numberValue,
              let max = object["max_offset_from_bottom"]?.numberValue,
              let rows = object["viewport_rows"]?.numberValue else { return nil }
        return PaneScroll(
            offsetFromBottom: Int(offset),
            maxOffsetFromBottom: Int(max),
            viewportRows: Int(rows)
        )
    }
    public var workspaceID: String? { data["workspace_id"]?.stringValue }
    public var tabID: String? { data["tab_id"]?.stringValue }
}
