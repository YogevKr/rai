import Foundation

/// Version of rai's WebSocket bridge protocol.
///
/// Versioning is independent of herdr's RPC protocol so the Mac and companion
/// app can negotiate their wire contract without exposing daemon internals.
public let bridgeProtocolVersion = 5

public struct ClientInfo: Codable, Equatable, Sendable {
    public let deviceID: String
    public let name: String
    public let platform: String

    public init(deviceID: String, name: String, platform: String) {
        self.deviceID = deviceID
        self.name = name
        self.platform = platform
    }
}

public struct BridgeEvent: Codable, Equatable, Sendable {
    public let name: String
    public let payload: [String: JSONValue]

    public init(name: String, payload: [String: JSONValue] = [:]) {
        self.name = name
        self.payload = payload
    }
}

/// One discriminated envelope is used in both directions. A flat `type` field
/// keeps frames easy to inspect and permits clients in languages other than
/// Swift without relying on Swift enum synthesis.
public enum BridgeMessage: Codable, Equatable, Sendable {
    // Client -> server
    case hello(token: String, client: ClientInfo)
    case subscribe
    case attachStream(paneID: String, cols: Int, rows: Int)
    case detachStream(paneID: String)
    case input(paneID: String, bytesBase64: String)
    case sendImage(paneID: String, bytesBase64: String, filename: String)
    case focusPane(paneID: String)
    case selectPane(paneID: String)
    case resizePane(paneID: String, cols: Int, rows: Int)
    case launchAgent(workspaceID: String?, agent: String, cwd: String?)
    case renamePane(paneID: String, label: String)
    case renameTab(tabID: String, label: String)
    case closePane(paneID: String)
    case closeTab(tabID: String)
    case registerPush(deviceToken: String, environment: String)
    case unregisterPush(deviceToken: String)
    /// Request the pane's recent scrollback (herdr's remote history) so the
    /// companion can seed its local buffer before the live frame stream —
    /// agent TUIs run on the alt screen, which never produces local scrollback.
    case readScrollback(paneID: String, lines: Int, rows: Int)

    // Server -> client
    case welcome(protocolVersion: Int, sessionName: String?)
    case authFailed(reason: String)
    case snapshot(SessionSnapshot)
    case event(BridgeEvent)
    case paneFrame(paneID: String, bytesBase64: String, full: Bool, seq: Int)
    /// ANSI-formatted scrollback history for a pane, sent before its stream's
    /// first frame. Clients that never sent readScrollback never receive it.
    case scrollback(paneID: String, bytesBase64: String)
    case error(message: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case token, client
        case paneID, tabID, workspaceID, agent, cwd, label
        case bytesBase64, filename
        case cols, rows
        case full, seq
        case protocolVersion, sessionName
        case reason, snapshot, event, message
        case deviceToken, environment
        case lines
    }

    private enum MessageType: String, Codable {
        case hello, subscribe, attachStream, detachStream
        case input, sendImage, focusPane, selectPane, resizePane
        case launchAgent, renamePane, renameTab, closePane, closeTab
        case registerPush, unregisterPush
        case readScrollback, scrollback
        case welcome, authFailed, snapshot, event, paneFrame, error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(MessageType.self, forKey: .type) {
        case .hello:
            self = .hello(
                token: try container.decode(String.self, forKey: .token),
                client: try container.decode(ClientInfo.self, forKey: .client)
            )
        case .subscribe:
            self = .subscribe
        case .attachStream:
            self = .attachStream(
                paneID: try container.decode(String.self, forKey: .paneID),
                cols: try container.decode(Int.self, forKey: .cols),
                rows: try container.decode(Int.self, forKey: .rows)
            )
        case .detachStream:
            self = .detachStream(paneID: try container.decode(String.self, forKey: .paneID))
        case .input:
            self = .input(
                paneID: try container.decode(String.self, forKey: .paneID),
                bytesBase64: try container.decode(String.self, forKey: .bytesBase64)
            )
        case .sendImage:
            self = .sendImage(
                paneID: try container.decode(String.self, forKey: .paneID),
                bytesBase64: try container.decode(String.self, forKey: .bytesBase64),
                filename: try container.decode(String.self, forKey: .filename)
            )
        case .focusPane:
            self = .focusPane(paneID: try container.decode(String.self, forKey: .paneID))
        case .selectPane:
            self = .selectPane(paneID: try container.decode(String.self, forKey: .paneID))
        case .resizePane:
            self = .resizePane(
                paneID: try container.decode(String.self, forKey: .paneID),
                cols: try container.decode(Int.self, forKey: .cols),
                rows: try container.decode(Int.self, forKey: .rows)
            )
        case .launchAgent:
            self = .launchAgent(
                workspaceID: try container.decodeIfPresent(String.self, forKey: .workspaceID),
                agent: try container.decode(String.self, forKey: .agent),
                cwd: try container.decodeIfPresent(String.self, forKey: .cwd)
            )
        case .renamePane:
            self = .renamePane(
                paneID: try container.decode(String.self, forKey: .paneID),
                label: try container.decode(String.self, forKey: .label)
            )
        case .renameTab:
            self = .renameTab(
                tabID: try container.decode(String.self, forKey: .tabID),
                label: try container.decode(String.self, forKey: .label)
            )
        case .closePane:
            self = .closePane(paneID: try container.decode(String.self, forKey: .paneID))
        case .closeTab:
            self = .closeTab(tabID: try container.decode(String.self, forKey: .tabID))
        case .registerPush:
            self = .registerPush(
                deviceToken: try container.decode(String.self, forKey: .deviceToken),
                environment: try container.decode(String.self, forKey: .environment)
            )
        case .unregisterPush:
            self = .unregisterPush(
                deviceToken: try container.decode(String.self, forKey: .deviceToken)
            )
        case .readScrollback:
            self = .readScrollback(
                paneID: try container.decode(String.self, forKey: .paneID),
                lines: try container.decode(Int.self, forKey: .lines),
                rows: try container.decode(Int.self, forKey: .rows)
            )
        case .scrollback:
            self = .scrollback(
                paneID: try container.decode(String.self, forKey: .paneID),
                bytesBase64: try container.decode(String.self, forKey: .bytesBase64)
            )
        case .welcome:
            self = .welcome(
                protocolVersion: try container.decode(Int.self, forKey: .protocolVersion),
                sessionName: try container.decodeIfPresent(String.self, forKey: .sessionName)
            )
        case .authFailed:
            self = .authFailed(reason: try container.decode(String.self, forKey: .reason))
        case .snapshot:
            self = .snapshot(try container.decode(SessionSnapshot.self, forKey: .snapshot))
        case .event:
            self = .event(try container.decode(BridgeEvent.self, forKey: .event))
        case .paneFrame:
            self = .paneFrame(
                paneID: try container.decode(String.self, forKey: .paneID),
                bytesBase64: try container.decode(String.self, forKey: .bytesBase64),
                full: try container.decode(Bool.self, forKey: .full),
                seq: try container.decode(Int.self, forKey: .seq)
            )
        case .error:
            self = .error(message: try container.decode(String.self, forKey: .message))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .hello(token, client):
            try container.encode(MessageType.hello, forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encode(client, forKey: .client)
        case .subscribe:
            try container.encode(MessageType.subscribe, forKey: .type)
        case let .attachStream(paneID, cols, rows):
            try container.encode(MessageType.attachStream, forKey: .type)
            try container.encode(paneID, forKey: .paneID)
            try container.encode(cols, forKey: .cols)
            try container.encode(rows, forKey: .rows)
        case let .detachStream(paneID):
            try container.encode(MessageType.detachStream, forKey: .type)
            try container.encode(paneID, forKey: .paneID)
        case let .input(paneID, bytesBase64):
            try container.encode(MessageType.input, forKey: .type)
            try container.encode(paneID, forKey: .paneID)
            try container.encode(bytesBase64, forKey: .bytesBase64)
        case let .sendImage(paneID, bytesBase64, filename):
            try container.encode(MessageType.sendImage, forKey: .type)
            try container.encode(paneID, forKey: .paneID)
            try container.encode(bytesBase64, forKey: .bytesBase64)
            try container.encode(filename, forKey: .filename)
        case let .focusPane(paneID):
            try container.encode(MessageType.focusPane, forKey: .type)
            try container.encode(paneID, forKey: .paneID)
        case let .selectPane(paneID):
            try container.encode(MessageType.selectPane, forKey: .type)
            try container.encode(paneID, forKey: .paneID)
        case let .resizePane(paneID, cols, rows):
            try container.encode(MessageType.resizePane, forKey: .type)
            try container.encode(paneID, forKey: .paneID)
            try container.encode(cols, forKey: .cols)
            try container.encode(rows, forKey: .rows)
        case let .launchAgent(workspaceID, agent, cwd):
            try container.encode(MessageType.launchAgent, forKey: .type)
            try container.encodeIfPresent(workspaceID, forKey: .workspaceID)
            try container.encode(agent, forKey: .agent)
            try container.encodeIfPresent(cwd, forKey: .cwd)
        case let .renamePane(paneID, label):
            try container.encode(MessageType.renamePane, forKey: .type)
            try container.encode(paneID, forKey: .paneID)
            try container.encode(label, forKey: .label)
        case let .renameTab(tabID, label):
            try container.encode(MessageType.renameTab, forKey: .type)
            try container.encode(tabID, forKey: .tabID)
            try container.encode(label, forKey: .label)
        case let .closePane(paneID):
            try container.encode(MessageType.closePane, forKey: .type)
            try container.encode(paneID, forKey: .paneID)
        case let .closeTab(tabID):
            try container.encode(MessageType.closeTab, forKey: .type)
            try container.encode(tabID, forKey: .tabID)
        case let .registerPush(deviceToken, environment):
            try container.encode(MessageType.registerPush, forKey: .type)
            try container.encode(deviceToken, forKey: .deviceToken)
            try container.encode(environment, forKey: .environment)
        case let .unregisterPush(deviceToken):
            try container.encode(MessageType.unregisterPush, forKey: .type)
            try container.encode(deviceToken, forKey: .deviceToken)
        case let .readScrollback(paneID, lines, rows):
            try container.encode(MessageType.readScrollback, forKey: .type)
            try container.encode(paneID, forKey: .paneID)
            try container.encode(lines, forKey: .lines)
            try container.encode(rows, forKey: .rows)
        case let .scrollback(paneID, bytesBase64):
            try container.encode(MessageType.scrollback, forKey: .type)
            try container.encode(paneID, forKey: .paneID)
            try container.encode(bytesBase64, forKey: .bytesBase64)
        case let .welcome(protocolVersion, sessionName):
            try container.encode(MessageType.welcome, forKey: .type)
            try container.encode(protocolVersion, forKey: .protocolVersion)
            try container.encodeIfPresent(sessionName, forKey: .sessionName)
        case let .authFailed(reason):
            try container.encode(MessageType.authFailed, forKey: .type)
            try container.encode(reason, forKey: .reason)
        case let .snapshot(snapshot):
            try container.encode(MessageType.snapshot, forKey: .type)
            try container.encode(snapshot, forKey: .snapshot)
        case let .event(event):
            try container.encode(MessageType.event, forKey: .type)
            try container.encode(event, forKey: .event)
        case let .paneFrame(paneID, bytesBase64, full, seq):
            try container.encode(MessageType.paneFrame, forKey: .type)
            try container.encode(paneID, forKey: .paneID)
            try container.encode(bytesBase64, forKey: .bytesBase64)
            try container.encode(full, forKey: .full)
            try container.encode(seq, forKey: .seq)
        case let .error(message):
            try container.encode(MessageType.error, forKey: .type)
            try container.encode(message, forKey: .message)
        }
    }
}
