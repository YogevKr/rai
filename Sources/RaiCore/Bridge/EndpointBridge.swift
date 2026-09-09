import Foundation

public struct EndpointViewIdentity: Codable, Equatable, Sendable {
    public let connectionID: String
    public let viewID: UUID
    public let machineEndpoint: MachineEndpoint?

    public init(connectionID: String, viewID: UUID = UUID(), machineEndpoint: MachineEndpoint? = nil) {
        self.connectionID = connectionID
        self.viewID = viewID
        self.machineEndpoint = machineEndpoint
    }
}

public enum EndpointBridgeInput: Codable, Equatable, Sendable {
    case text(String), paste(String)
    case special(EndpointKey.Special, modifiers: UInt8)
    case character(String, modifiers: UInt8)
    case function(UInt8, modifiers: UInt8)
    case mouse(EndpointMouse)

    public static func terminalBytes(_ bytes: ArraySlice<UInt8>) -> Self? {
        guard let text = String(bytes: bytes, encoding: .utf8) else { return nil }
        let keys: [String: EndpointKey.Special] = ["\r": .enter, "\n": .enter, "\t": .tab,
            "\u{7f}": .backspace, "\u{8}": .backspace, "\u{1b}": .escape,
            "\u{1b}[A": .up, "\u{1b}[B": .down, "\u{1b}[C": .right, "\u{1b}[D": .left,
            "\u{1b}[H": .home, "\u{1b}[F": .end, "\u{1b}[2~": .insert,
            "\u{1b}[3~": .delete, "\u{1b}[5~": .pageUp, "\u{1b}[6~": .pageDown, "\u{1b}[Z": .backTab]
        if let key = keys[text] { return .special(key, modifiers: key == .backTab ? 1 : 0) }
        if bytes.count == 1, let byte = bytes.first, (1...26).contains(byte) {
            return .character(String(UnicodeScalar(UInt32(byte) + 96)!), modifiers: 2)
        }
        return .text(text)
    }

    public func input() throws -> EndpointInput {
        switch self {
        case .mouse(let mouse):
            guard mouse.isValid else { throw HerdrEndpointError.malformed }
            return .mouse(mouse)
        case .text(let text), .paste(let text):
            guard text.utf8.count <= 1_000_000 else { throw HerdrEndpointError.limitExceeded }
            if case .paste = self { return .paste(text) }
            return .text(text)
        case .special(let key, let modifiers): return .key(EndpointKey(code: .special(key), modifiers: modifiers))
        case .character(let text, let modifiers):
            guard text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first else { throw HerdrEndpointError.malformed }
            return .key(EndpointKey(code: .character(scalar), modifiers: modifiers))
        case .function(let number, let modifiers):
            guard (1...35).contains(number) else { throw HerdrEndpointError.malformed }
            return .key(EndpointKey(code: .function(number), modifiers: modifiers))
        }
    }
}

/// Closed operations prevent bridge clients from forwarding arbitrary RPC or shell commands.
public enum EndpointBridgeCommand: Codable, Equatable, Sendable {
    public enum Direction: String, Codable, Sendable { case left, right, up, down }
    case focusPane(String), focusTab(String), focusWorkspace(String)
    case createTab(workspaceID: String), createWorkspace(sourceWorkspaceID: String)
    case split(paneID: String, direction: Direction), focusDirection(paneID: String, direction: Direction)
    case closePane(String), closeTab(String), zoom(String)
    case scroll(paneID: String, offset: UInt64)
    case invoke(EndpointCommandInvocation)
    case renamePane(String, label: String), renameTab(String, label: String), renameWorkspace(String, label: String)

    public var rpc: (method: String, params: [String: JSONValue]) {
        switch self {
        case .invoke(let invocation): return ("command.invoke", invocation.params)
        case .focusPane(let id): return ("pane.focus", ["pane_id": .string(id)])
        case .focusTab(let id): return ("tab.focus", ["tab_id": .string(id)])
        case .focusWorkspace(let id): return ("workspace.focus", ["workspace_id": .string(id)])
        case .createTab(let id): return ("tab.create", ["workspace_id": .string(id), "focus": .bool(true)])
        case .createWorkspace(let id): return ("workspace.create", ["source_workspace_id": .string(id), "focus": .bool(true)])
        case .split(let id, let direction):
            return ("pane.split", ["target_pane_id": .string(id), "direction": .string(direction.rawValue), "focus": .bool(true)])
        case .focusDirection(let id, let direction):
            return ("pane.focus_direction", ["pane_id": .string(id), "direction": .string(direction.rawValue)])
        case .closePane(let id): return ("pane.close", ["pane_id": .string(id)])
        case .closeTab(let id): return ("tab.close", ["tab_id": .string(id)])
        case .scroll(let id, let offset):
            return ("pane.scroll", ["pane_id": .string(id), "offset_from_bottom": .number(Double(min(offset, EndpointScroll.maximumOffset)))])
        case .zoom(let id): return ("pane.zoom", ["pane_id": .string(id), "mode": .string("toggle")])
        case .renamePane(let id, let label): return ("pane.rename", ["pane_id": .string(id), "label": .string(label)])
        case .renameTab(let id, let label): return ("tab.rename", ["tab_id": .string(id), "label": .string(label)])
        case .renameWorkspace(let id, let label): return ("workspace.rename", ["workspace_id": .string(id), "label": .string(label)])
        }
    }
}

public enum EndpointBridgeOperation: Codable, Equatable, Sendable {
    case open(columns: Int, rows: Int), close, resize(columns: Int, rows: Int)
    case input(paneID: String, input: EndpointBridgeInput)
    case popupInput(terminalID: String, input: EndpointBridgeInput)
    case command(EndpointBridgeCommand)
    case plugin(EndpointPluginRequest)
    case layout(EndpointLayoutRequest)
    case launchAgent(EndpointAgentLaunchRequest)
    case worktree(EndpointWorktreeRequest)
    case terminalAction(EndpointTextRequest)
}

public struct EndpointBridgeRequest: Codable, Equatable, Sendable {
    public let identity: EndpointViewIdentity
    public let sequence: UInt64
    public let bootID: String?
    public let projectionRevision: UInt64?
    public let operation: EndpointBridgeOperation
    public var requestID: String { "\(identity.viewID.uuidString):\(sequence)" }

    public init(identity: EndpointViewIdentity, sequence: UInt64, bootID: String? = nil,
                projectionRevision: UInt64? = nil, operation: EndpointBridgeOperation) {
        self.identity = identity; self.sequence = sequence; self.bootID = bootID
        self.projectionRevision = projectionRevision; self.operation = operation
    }
}

public struct EndpointBridgeState: Codable, Equatable, Sendable {
    public let identity: EndpointViewIdentity
    public let sequence: UInt64
    public let snapshot: HerdrEndpointSnapshot?
    public var surface: HerdrEndpointSurface?
    public let methods: [String]
    public var agentLaunchResult: EndpointAgentLaunchResult?
    public var pluginResult: EndpointPluginResult?
    public var notifications: [EndpointNotification]?
    public var windowTitle: String?
    public var graphicsPolicyWarning: String?
    public var retainsHostConnection: Bool?
    public let busy: Bool
    public let error: String?
    public let worktreeResult: EndpointWorktreeResult?
    public var terminalResult: EndpointTextResult?
    public var layoutResult: EndpointLayoutResult?

    public init(identity: EndpointViewIdentity, sequence: UInt64, snapshot: HerdrEndpointSnapshot?,
                surface: HerdrEndpointSurface?, methods: [String], busy: Bool, error: String?, worktreeResult: EndpointWorktreeResult? = nil) {
        self.identity = identity; self.sequence = sequence; self.snapshot = snapshot; self.surface = surface
        self.methods = methods; self.busy = busy; self.error = error; self.worktreeResult = worktreeResult
    }
}
