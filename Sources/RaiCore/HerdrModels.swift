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
    public let repoKey: String?
    public let repoName: String
    public let repoRoot: String?
    public let checkoutPath: String
    public let isLinkedWorktree: Bool

    enum CodingKeys: String, CodingKey {
        case repoKey = "repo_key"
        case repoName = "repo_name"
        case repoRoot = "repo_root"
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

// Herdr auto-names tabs from the terminal title, so an agent's status glyph
// gets frozen into the label too ("◑ Get started with…"). Strip it the same
// way pane titles are stripped; a glyph-only label decays to the empty label,
// which display code already renders as the tab number.
extension HerdrTab {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tabID = try container.decode(String.self, forKey: .tabID)
        workspaceID = try container.decode(String.self, forKey: .workspaceID)
        number = try container.decode(Int.self, forKey: .number)
        label = AgentTitleGlyphs.strip(
            try container.decode(String.self, forKey: .label)
        ) ?? ""
        focused = try container.decode(Bool.self, forKey: .focused)
        paneCount = try container.decode(Int.self, forKey: .paneCount)
        agentStatus = try container.decode(AgentStatus.self, forKey: .agentStatus)
    }

    /// A blank label, or one that's just herdr's own auto-assigned tab
    /// number (e.g. "3"), carries no real title — display code on every
    /// platform must fall back past it instead of showing the digits.
    public var hasUsefulLabel: Bool {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && Int(trimmed) == nil
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

public struct AgentResumePlan: Sendable, Equatable {
    public let resumeArgv: [String]
    public let fallbackArgv: [String]
}

public struct AgentSession: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case id
        case path
    }

    public let agent: String
    public let kind: Kind
    public let source: String
    public let value: String

    /// Herdr accepts exact resume ids only from its official agent reporters.
    /// Keep the same trust boundary before putting a wire value into a shell.
    public func exactResumePlan(argv: [String]?) -> AgentResumePlan? {
        guard kind == .id,
              source == "herdr:\(agent)",
              ["claude", "codex"].contains(agent),
              !value.isEmpty,
              value.utf8.count <= 512,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              })
        else {
            return nil
        }
        var tokens = argv ?? []
        if tokens.isEmpty || (tokens[0] as NSString).lastPathComponent != agent {
            tokens = [agent]
        } else {
            tokens[0] = agent
        }
        switch agent {
        case "claude":
            let fresh = [agent] + Self.claudeLaunchOptions(tokens.dropFirst())
            return AgentResumePlan(
                resumeArgv: fresh + ["--resume", value],
                fallbackArgv: fresh
            )
        case "codex":
            if let resumeIndex = tokens.firstIndex(of: "resume") {
                let prefix = Self.codexLaunchOptions(
                    tokens[tokens.index(after: tokens.startIndex)..<resumeIndex]
                )
                let suffix = Self.codexLaunchOptions(
                    tokens[tokens.index(after: resumeIndex)...],
                    dropping: ["--last", "--all", "--include-non-interactive"]
                )
                let fresh = [agent] + prefix + suffix
                return AgentResumePlan(
                    resumeArgv: [agent] + prefix + ["resume", value] + suffix,
                    fallbackArgv: fresh
                )
            }
            let fresh = [agent] + Self.codexLaunchOptions(tokens.dropFirst())
            return AgentResumePlan(
                resumeArgv: fresh + ["resume", value],
                fallbackArgv: fresh
            )
        default:
            return nil
        }
    }

    private static func claudeLaunchOptions(
        _ tokens: ArraySlice<String>
    ) -> [String] {
        let values: Set<String> = [
            "--agent", "--agents",
            "--append-system-prompt",
            "--debug-file",
            "--effort",
            "--fallback-model",
            "--input-format",
            "--json-schema",
            "--max-budget-usd",
            "--model",
            "-n", "--name",
            "--output-format",
            "--permission-mode",
            "--plugin-dir", "--plugin-url",
            "--remote-control-session-name-prefix",
            "--setting-sources", "--settings",
            "--system-prompt",
        ]
        let optionalValues: Set<String> = [
            "-d", "--debug",
            "--from-pr",
            "--prompt-suggestions",
            "--remote-control",
            "-w", "--worktree",
        ]
        let variadicValues: Set<String> = [
            "--add-dir",
            "--allowedTools", "--allowed-tools",
            "--betas",
            "--disallowedTools", "--disallowed-tools",
            "--file",
            "--mcp-config",
            "--tools",
        ]
        var filtered: [String] = []
        var index = tokens.startIndex
        while index < tokens.endIndex {
            let token = tokens[index]
            if token == "--" {
                break
            } else if token == "--session-id" {
                index += min(2, tokens.distance(from: index, to: tokens.endIndex))
            } else if token.hasPrefix("--session-id=")
                || token == "--fork-session" {
                index += 1
            } else if ["-c", "--continue", "-r", "--resume"].contains(token) {
                index += 1
                if ["-r", "--resume"].contains(token),
                   index < tokens.endIndex,
                   !tokens[index].hasPrefix("-") {
                    index += 1
                }
            } else if token.hasPrefix("--resume=")
                || token.hasPrefix("-r=")
                || token.hasPrefix("-r") && token != "-r" {
                index += 1
            } else if values.contains(token) {
                filtered.append(token)
                index += 1
                if index < tokens.endIndex {
                    filtered.append(tokens[index])
                    index += 1
                }
            } else if optionalValues.contains(token) {
                filtered.append(token)
                index += 1
                if index < tokens.endIndex, !tokens[index].hasPrefix("-") {
                    filtered.append(tokens[index])
                    index += 1
                }
            } else if variadicValues.contains(token) {
                filtered.append(token)
                index += 1
                while index < tokens.endIndex, !tokens[index].hasPrefix("-") {
                    filtered.append(tokens[index])
                    index += 1
                }
            } else if token.hasPrefix("-") {
                filtered.append(token)
                index += 1
            } else {
                index += 1
            }
        }
        return filtered
    }

    private static func codexLaunchOptions(
        _ tokens: ArraySlice<String>,
        dropping dropped: Set<String> = []
    ) -> [String] {
        let values: Set<String> = [
            "-c", "--config",
            "--enable", "--disable",
            "--remote", "--remote-auth-token-env",
            "-m", "--model",
            "--local-provider",
            "-p", "--profile",
            "-s", "--sandbox",
            "-C", "--cd",
            "--add-dir",
            "-a", "--ask-for-approval",
        ]
        let variadicValues: Set<String> = ["-i", "--image"]
        var filtered: [String] = []
        var index = tokens.startIndex
        while index < tokens.endIndex {
            let token = tokens[index]
            if token == "--" {
                break
            } else if dropped.contains(token) {
                index += 1
            } else if values.contains(token) {
                filtered.append(token)
                index += 1
                if index < tokens.endIndex {
                    filtered.append(tokens[index])
                    index += 1
                }
            } else if variadicValues.contains(token) {
                filtered.append(token)
                index += 1
                while index < tokens.endIndex, !tokens[index].hasPrefix("-") {
                    filtered.append(tokens[index])
                    index += 1
                }
            } else if token.hasPrefix("-") {
                filtered.append(token)
                index += 1
            } else {
                index += 1
            }
        }
        return filtered
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
    public let agentSession: AgentSession?
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
        case agentSession = "agent_session"
        case foregroundCWD = "foreground_cwd"
        case terminalTitle = "terminal_title"
        case terminalTitleStripped = "terminal_title_stripped"
        case agentStatus = "agent_status"
    }
}

// Decoding lives in an extension so tests keep the memberwise init. Herdr's
// stripping lags upstream glyph changes; see AgentTitleGlyphs.
extension Pane {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        paneID = try container.decode(String.self, forKey: .paneID)
        terminalID = try container.decode(String.self, forKey: .terminalID)
        workspaceID = try container.decode(String.self, forKey: .workspaceID)
        tabID = try container.decode(String.self, forKey: .tabID)
        focused = try container.decode(Bool.self, forKey: .focused)
        cwd = try container.decode(String.self, forKey: .cwd)
        foregroundCWD = try container.decodeIfPresent(
            String.self, forKey: .foregroundCWD
        )
        agent = try container.decodeIfPresent(String.self, forKey: .agent)
        agentSession = try container.decodeIfPresent(
            AgentSession.self, forKey: .agentSession
        )
        terminalTitle = try container.decodeIfPresent(
            String.self, forKey: .terminalTitle
        )
        terminalTitleStripped = AgentTitleGlyphs.strip(
            try container.decodeIfPresent(
                String.self, forKey: .terminalTitleStripped
            )
        )
        agentStatus = try container.decode(AgentStatus.self, forKey: .agentStatus)
        revision = try container.decode(UInt64.self, forKey: .revision)
        scroll = try container.decodeIfPresent(PaneScroll.self, forKey: .scroll)
    }
}

public struct HerdrAgent: Codable, Identifiable, Sendable, Equatable {
    public let terminalID: String
    public let name: String?
    public let agent: String?
    public let title: String?
    public let terminalTitle: String?
    public let terminalTitleStripped: String?
    public let displayAgent: String?
    public let agentStatus: AgentStatus
    public let agentSession: AgentSession?
    public let workspaceID: String
    public let tabID: String
    public let paneID: String
    public let focused: Bool
    public let cwd: String?
    public let foregroundCWD: String?
    public let revision: UInt64

    public var id: String { paneID }

    enum CodingKeys: String, CodingKey {
        case terminalID = "terminal_id"
        case name, agent, title
        case terminalTitle = "terminal_title"
        case terminalTitleStripped = "terminal_title_stripped"
        case displayAgent = "display_agent"
        case agentStatus = "agent_status"
        case agentSession = "agent_session"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case paneID = "pane_id"
        case focused, cwd, revision
        case foregroundCWD = "foreground_cwd"
    }
}

extension HerdrAgent {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        terminalID = try container.decode(String.self, forKey: .terminalID)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        agent = try container.decodeIfPresent(String.self, forKey: .agent)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        terminalTitle = try container.decodeIfPresent(
            String.self, forKey: .terminalTitle
        )
        terminalTitleStripped = AgentTitleGlyphs.strip(
            try container.decodeIfPresent(
                String.self, forKey: .terminalTitleStripped
            )
        )
        displayAgent = try container.decodeIfPresent(
            String.self, forKey: .displayAgent
        )
        agentStatus = try container.decode(AgentStatus.self, forKey: .agentStatus)
        agentSession = try container.decodeIfPresent(
            AgentSession.self, forKey: .agentSession
        )
        workspaceID = try container.decode(String.self, forKey: .workspaceID)
        tabID = try container.decode(String.self, forKey: .tabID)
        paneID = try container.decode(String.self, forKey: .paneID)
        focused = try container.decode(Bool.self, forKey: .focused)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        foregroundCWD = try container.decodeIfPresent(
            String.self, forKey: .foregroundCWD
        )
        revision = try container.decode(UInt64.self, forKey: .revision)
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
    public let agents: [HerdrAgent]?
    public let layouts: [PaneLayoutSnapshot]

    enum CodingKeys: String, CodingKey {
        case version, `protocol`, workspaces, tabs, panes, agents, layouts
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
