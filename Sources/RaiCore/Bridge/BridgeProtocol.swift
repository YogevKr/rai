import Foundation

/// Version of rai's WebSocket bridge protocol.
///
/// Versioning is independent of herdr's RPC protocol so the Mac and companion
/// app can negotiate their wire contract without exposing daemon internals.
public let bridgeProtocolVersion = 6

public struct ClientInfo: Codable, Equatable, Sendable {
    public let deviceID: String
    public let name: String
    public let platform: String
    public let model: String?

    public init(deviceID: String, name: String, platform: String, model: String? = nil) {
        self.deviceID = deviceID
        self.name = name
        self.platform = platform
        self.model = model
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
/// One pane's pending background work (shells, monitors, subagents,
/// workflows) as human-readable summaries — the phone's ⏳ signal.
public struct PaneBackgroundWork: Codable, Equatable, Sendable {
    public let paneID: String
    public let summaries: [String]

    public init(paneID: String, summaries: [String]) {
        self.paneID = paneID
        self.summaries = summaries
    }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case summaries
    }
}

/// A herdr session the Mac can attach to, for the phone's session switcher.
public struct BridgeSessionInfo: Codable, Equatable, Sendable {
    public let name: String
    public let isRunning: Bool
    public let isCurrent: Bool

    public init(name: String, isRunning: Bool, isCurrent: Bool) {
        self.name = name
        self.isRunning = isRunning
        self.isCurrent = isCurrent
    }

    enum CodingKeys: String, CodingKey {
        case name
        case isRunning = "is_running"
        case isCurrent = "is_current"
    }
}

public enum TranscriptHistoryState: String, Codable, Equatable, Sendable {
    case available
    case notFound = "not_found"
    case ambiguous
    case hookRequired = "hook_required"
}

public struct TranscriptHistoryPage: Codable, Equatable, Sendable {
    public let paneID: String
    public let sessionID: String
    public let resolvedSessionID: String?
    public let requestID: String
    public let herdSessionName: String?
    public let turns: [TranscriptTurn]
    public let hasMore: Bool
    public let sinceLastSeen: Int?
    public let state: TranscriptHistoryState

    public init(
        paneID: String,
        sessionID: String,
        resolvedSessionID: String? = nil,
        requestID: String = "",
        herdSessionName: String? = nil,
        turns: [TranscriptTurn],
        hasMore: Bool,
        sinceLastSeen: Int? = nil,
        state: TranscriptHistoryState = .available
    ) {
        self.paneID = paneID
        self.sessionID = sessionID
        self.resolvedSessionID = resolvedSessionID
        self.requestID = requestID
        self.herdSessionName = herdSessionName
        self.turns = turns
        self.hasMore = hasMore
        self.sinceLastSeen = sinceLastSeen
        self.state = state
    }

    public var agentSessionID: String {
        resolvedSessionID ?? sessionID
    }
}

public enum TranscriptPagination {
    public static let maximumLimit = 50
    public static let maximumTextBytes = 8_192

    public static func page(
        paneID: String,
        sessionID: String,
        herdSessionName: String? = nil,
        turns: [TranscriptTurn],
        beforeTurnIndex: Int?,
        limit: Int,
        sinceLastSeen: Int? = nil
    ) -> TranscriptHistoryPage {
        let boundedLimit = min(max(limit, 1), maximumLimit)
        let eligible = turns.filter { turn in
            beforeTurnIndex.map { turn.index < $0 } ?? true
        }
        let selected = eligible.suffix(boundedLimit).map(bound)
        return TranscriptHistoryPage(
            paneID: paneID,
            sessionID: sessionID,
            herdSessionName: herdSessionName,
            turns: selected,
            hasMore: eligible.count > selected.count,
            sinceLastSeen: sinceLastSeen
        )
    }

    private static func bound(_ turn: TranscriptTurn) -> TranscriptTurn {
        let boundedText = TranscriptReader.bytePrefix(turn.text, limit: maximumTextBytes)
        let boundedTool = turn.tool.map { tool in
            TranscriptTool(
                name: TranscriptReader.bytePrefix(
                    tool.name,
                    limit: TranscriptReader.maximumToolSummaryBytes
                ).text,
                summary: TranscriptReader.bytePrefix(
                    tool.summary,
                    limit: TranscriptReader.maximumToolSummaryBytes
                ).text
            )
        }
        let toolWasTruncated = zip(
            [turn.tool?.name, turn.tool?.summary].compactMap { $0 },
            [boundedTool?.name, boundedTool?.summary].compactMap { $0 }
        ).contains { pair in pair.0.utf8.count != pair.1.utf8.count }
        return TranscriptTurn(
            index: turn.index,
            role: turn.role,
            text: boundedText.text,
            tool: boundedTool,
            timestamp: turn.timestamp,
            truncated: turn.truncated || boundedText.truncated || toolWasTruncated
        )
    }
}

public enum BridgeMessage: Codable, Equatable, Sendable {
    // Client -> server
    case pair(code: String, protocolVersion: Int, client: ClientInfo)
    case hello(token: String, client: ClientInfo)
    case subscribe
    /// `fullGrid: true` (newer clients) opts into a stream that is never
    /// smaller than the pane's own grid: the server clamps the requested
    /// rows up to the pane height and the client scrolls a viewport over
    /// the full grid. Absent for older clients, whose emulator is sized
    /// to their view and would garble frames taller than it.
    case attachStream(paneID: String, cols: Int, rows: Int, fullGrid: Bool)
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
    case readScrollback(paneID: String, lines: Int, rows: Int, fullGrid: Bool)
    /// Named keypresses (herdr key names: "enter", "1", "ctrl+c", …) that must
    /// act as keystrokes, not pasted text — e.g. answering a Claude dialog.
    case sendKeys(paneID: String, keys: [String])
    case renameWorkspace(workspaceID: String, label: String)
    case closeWorkspace(workspaceID: String)
    case broadcastInput(tabID: String, text: String)
    case listSessions
    case selectSession(name: String)
    case history(
        paneID: String,
        sessionID: String,
        requestID: String,
        beforeTurnIndex: Int?,
        limit: Int,
        herdSessionName: String?
    )
    case historyReceived(
        paneID: String,
        sessionID: String,
        requestID: String,
        herdSessionName: String?,
        throughTurnIndex: Int?
    )

    // Server -> client
    case paired(token: String, protocolVersion: Int, sessionName: String?)
    case welcome(protocolVersion: Int, sessionName: String?)
    case authFailed(reason: String)
    case snapshot(SessionSnapshot, sessionName: String?)
    case event(BridgeEvent)
    /// `cols`/`rows` are the frame's grid dimensions (present on newer
    /// Macs): the client pins its emulator grid to them so a pane larger
    /// than the phone viewport scrolls instead of clipping.
    case paneFrame(paneID: String, bytesBase64: String, full: Bool, seq: Int, cols: Int?, rows: Int?)
    /// ANSI-formatted scrollback history for a pane, sent before its stream's
    /// first frame. Clients that never sent readScrollback never receive it.
    case scrollback(paneID: String, bytesBase64: String)
    case backgroundWork([PaneBackgroundWork])
    case sessions([BridgeSessionInfo])
    case historyPage(TranscriptHistoryPage)
    case historyError(
        paneID: String, sessionID: String, requestID: String, message: String
    )
    case error(message: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case token, code, client
        case fullGrid
        case paneID, tabID, workspaceID, agent, cwd, label
        case bytesBase64, filename
        case cols, rows
        case full, seq
        case protocolVersion, sessionName
        case reason, snapshot, event, message
        case deviceToken, environment
        case lines, keys
        case text, name, work, sessions
        case beforeTurnIndex, limit, sessionID, resolvedSessionID, requestID
        case turns, hasMore, sinceLastSeen, historyState
        case throughTurnIndex, herdSessionName
    }

    private enum MessageType: String, Codable {
        case pair, hello, subscribe, attachStream, detachStream
        case input, sendImage, focusPane, selectPane, resizePane
        case launchAgent, renamePane, renameTab, closePane, closeTab
        case registerPush, unregisterPush
        case readScrollback, scrollback, sendKeys
        case renameWorkspace, closeWorkspace, broadcastInput
        case listSessions, selectSession, history, historyReceived, historyPage, historyError
        case backgroundWork, sessions
        case paired, welcome, authFailed, snapshot, event, paneFrame, error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(MessageType.self, forKey: .type) {
        case .pair:
            self = .pair(
                code: try container.decode(String.self, forKey: .code),
                protocolVersion: try container.decode(Int.self, forKey: .protocolVersion),
                client: try container.decode(ClientInfo.self, forKey: .client)
            )
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
                rows: try container.decode(Int.self, forKey: .rows),
                fullGrid: try container.decodeIfPresent(Bool.self, forKey: .fullGrid) ?? false
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
                rows: try container.decode(Int.self, forKey: .rows),
                fullGrid: try container.decodeIfPresent(Bool.self, forKey: .fullGrid) ?? false
            )
        case .sendKeys:
            self = .sendKeys(
                paneID: try container.decode(String.self, forKey: .paneID),
                keys: try container.decode([String].self, forKey: .keys)
            )
        case .scrollback:
            self = .scrollback(
                paneID: try container.decode(String.self, forKey: .paneID),
                bytesBase64: try container.decode(String.self, forKey: .bytesBase64)
            )
        case .renameWorkspace:
            self = .renameWorkspace(
                workspaceID: try container.decode(String.self, forKey: .workspaceID),
                label: try container.decode(String.self, forKey: .label)
            )
        case .closeWorkspace:
            self = .closeWorkspace(
                workspaceID: try container.decode(String.self, forKey: .workspaceID)
            )
        case .broadcastInput:
            self = .broadcastInput(
                tabID: try container.decode(String.self, forKey: .tabID),
                text: try container.decode(String.self, forKey: .text)
            )
        case .listSessions:
            self = .listSessions
        case .selectSession:
            self = .selectSession(name: try container.decode(String.self, forKey: .name))
        case .history:
            self = .history(
                paneID: try container.decode(String.self, forKey: .paneID),
                sessionID: try container.decodeIfPresent(String.self, forKey: .sessionID) ?? "",
                requestID: try container.decodeIfPresent(String.self, forKey: .requestID) ?? "",
                beforeTurnIndex: try container.decodeIfPresent(
                    Int.self,
                    forKey: .beforeTurnIndex
                ),
                limit: try container.decode(Int.self, forKey: .limit),
                herdSessionName: try container.decodeIfPresent(
                    String.self,
                    forKey: .herdSessionName
                )
            )
        case .historyReceived:
            self = .historyReceived(
                paneID: try container.decode(String.self, forKey: .paneID),
                sessionID: try container.decode(String.self, forKey: .sessionID),
                requestID: try container.decodeIfPresent(String.self, forKey: .requestID) ?? "",
                herdSessionName: try container.decodeIfPresent(
                    String.self,
                    forKey: .herdSessionName
                ),
                throughTurnIndex: try container.decodeIfPresent(
                    Int.self,
                    forKey: .throughTurnIndex
                )
            )
        case .historyPage:
            self = .historyPage(TranscriptHistoryPage(
                paneID: try container.decode(String.self, forKey: .paneID),
                sessionID: try container.decode(String.self, forKey: .sessionID),
                resolvedSessionID: try container.decodeIfPresent(
                    String.self, forKey: .resolvedSessionID
                ),
                requestID: try container.decodeIfPresent(String.self, forKey: .requestID) ?? "",
                herdSessionName: try container.decodeIfPresent(
                    String.self,
                    forKey: .herdSessionName
                ),
                turns: try container.decode([TranscriptTurn].self, forKey: .turns),
                hasMore: try container.decode(Bool.self, forKey: .hasMore),
                sinceLastSeen: try container.decodeIfPresent(Int.self, forKey: .sinceLastSeen),
                state: try container.decodeIfPresent(
                    TranscriptHistoryState.self, forKey: .historyState
                ) ?? .available
            ))
        case .historyError:
            self = .historyError(
                paneID: try container.decode(String.self, forKey: .paneID),
                sessionID: try container.decode(String.self, forKey: .sessionID),
                requestID: try container.decode(String.self, forKey: .requestID),
                message: try container.decode(String.self, forKey: .message)
            )
        case .backgroundWork:
            self = .backgroundWork(
                try container.decode([PaneBackgroundWork].self, forKey: .work)
            )
        case .sessions:
            self = .sessions(
                try container.decode([BridgeSessionInfo].self, forKey: .sessions)
            )
        case .paired:
            self = .paired(
                token: try container.decode(String.self, forKey: .token),
                protocolVersion: try container.decode(Int.self, forKey: .protocolVersion),
                sessionName: try container.decodeIfPresent(String.self, forKey: .sessionName)
            )
        case .welcome:
            self = .welcome(
                protocolVersion: try container.decode(Int.self, forKey: .protocolVersion),
                sessionName: try container.decodeIfPresent(String.self, forKey: .sessionName)
            )
        case .authFailed:
            self = .authFailed(reason: try container.decode(String.self, forKey: .reason))
        case .snapshot:
            self = .snapshot(
                try container.decode(SessionSnapshot.self, forKey: .snapshot),
                sessionName: try container.decodeIfPresent(String.self, forKey: .sessionName)
            )
        case .event:
            self = .event(try container.decode(BridgeEvent.self, forKey: .event))
        case .paneFrame:
            self = .paneFrame(
                paneID: try container.decode(String.self, forKey: .paneID),
                bytesBase64: try container.decode(String.self, forKey: .bytesBase64),
                full: try container.decode(Bool.self, forKey: .full),
                seq: try container.decode(Int.self, forKey: .seq),
                cols: try container.decodeIfPresent(Int.self, forKey: .cols),
                rows: try container.decodeIfPresent(Int.self, forKey: .rows)
            )
        case .error:
            self = .error(message: try container.decode(String.self, forKey: .message))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .pair(code, protocolVersion, client):
            try container.encode(MessageType.pair, forKey: .type)
            try container.encode(code, forKey: .code)
            try container.encode(protocolVersion, forKey: .protocolVersion)
            try container.encode(client, forKey: .client)
        case let .hello(token, client):
            try container.encode(MessageType.hello, forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encode(client, forKey: .client)
        case .subscribe:
            try container.encode(MessageType.subscribe, forKey: .type)
        case let .attachStream(paneID, cols, rows, fullGrid):
            try container.encode(MessageType.attachStream, forKey: .type)
            try container.encode(paneID, forKey: .paneID)
            try container.encode(cols, forKey: .cols)
            try container.encode(rows, forKey: .rows)
            try container.encode(fullGrid, forKey: .fullGrid)
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
        case let .readScrollback(paneID, lines, rows, fullGrid):
            try container.encode(MessageType.readScrollback, forKey: .type)
            try container.encode(paneID, forKey: .paneID)
            try container.encode(lines, forKey: .lines)
            try container.encode(rows, forKey: .rows)
            try container.encode(fullGrid, forKey: .fullGrid)
        case let .sendKeys(paneID, keys):
            try container.encode(MessageType.sendKeys, forKey: .type)
            try container.encode(paneID, forKey: .paneID)
            try container.encode(keys, forKey: .keys)
        case let .scrollback(paneID, bytesBase64):
            try container.encode(MessageType.scrollback, forKey: .type)
            try container.encode(paneID, forKey: .paneID)
            try container.encode(bytesBase64, forKey: .bytesBase64)
        case let .renameWorkspace(workspaceID, label):
            try container.encode(MessageType.renameWorkspace, forKey: .type)
            try container.encode(workspaceID, forKey: .workspaceID)
            try container.encode(label, forKey: .label)
        case let .closeWorkspace(workspaceID):
            try container.encode(MessageType.closeWorkspace, forKey: .type)
            try container.encode(workspaceID, forKey: .workspaceID)
        case let .broadcastInput(tabID, text):
            try container.encode(MessageType.broadcastInput, forKey: .type)
            try container.encode(tabID, forKey: .tabID)
            try container.encode(text, forKey: .text)
        case .listSessions:
            try container.encode(MessageType.listSessions, forKey: .type)
        case let .selectSession(name):
            try container.encode(MessageType.selectSession, forKey: .type)
            try container.encode(name, forKey: .name)
        case let .history(
            paneID, sessionID, requestID, beforeTurnIndex, limit, herdSessionName
        ):
            try container.encode(MessageType.history, forKey: .type)
            try container.encode(paneID, forKey: .paneID)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(requestID, forKey: .requestID)
            try container.encodeIfPresent(beforeTurnIndex, forKey: .beforeTurnIndex)
            try container.encode(limit, forKey: .limit)
            try container.encodeIfPresent(herdSessionName, forKey: .herdSessionName)
        case let .historyReceived(
            paneID, sessionID, requestID, herdSessionName, throughTurnIndex
        ):
            try container.encode(MessageType.historyReceived, forKey: .type)
            try container.encode(paneID, forKey: .paneID)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(requestID, forKey: .requestID)
            try container.encodeIfPresent(herdSessionName, forKey: .herdSessionName)
            try container.encodeIfPresent(throughTurnIndex, forKey: .throughTurnIndex)
        case let .backgroundWork(work):
            try container.encode(MessageType.backgroundWork, forKey: .type)
            try container.encode(work, forKey: .work)
        case let .sessions(sessions):
            try container.encode(MessageType.sessions, forKey: .type)
            try container.encode(sessions, forKey: .sessions)
        case let .historyPage(page):
            try container.encode(MessageType.historyPage, forKey: .type)
            try container.encode(page.paneID, forKey: .paneID)
            try container.encode(page.sessionID, forKey: .sessionID)
            try container.encodeIfPresent(page.resolvedSessionID, forKey: .resolvedSessionID)
            try container.encode(page.requestID, forKey: .requestID)
            try container.encodeIfPresent(page.herdSessionName, forKey: .herdSessionName)
            try container.encode(page.turns, forKey: .turns)
            try container.encode(page.hasMore, forKey: .hasMore)
            try container.encodeIfPresent(page.sinceLastSeen, forKey: .sinceLastSeen)
            try container.encode(page.state, forKey: .historyState)
        case let .historyError(paneID, sessionID, requestID, message):
            try container.encode(MessageType.historyError, forKey: .type)
            try container.encode(paneID, forKey: .paneID)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(requestID, forKey: .requestID)
            try container.encode(message, forKey: .message)
        case let .paired(token, protocolVersion, sessionName):
            try container.encode(MessageType.paired, forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encode(protocolVersion, forKey: .protocolVersion)
            try container.encodeIfPresent(sessionName, forKey: .sessionName)
        case let .welcome(protocolVersion, sessionName):
            try container.encode(MessageType.welcome, forKey: .type)
            try container.encode(protocolVersion, forKey: .protocolVersion)
            try container.encodeIfPresent(sessionName, forKey: .sessionName)
        case let .authFailed(reason):
            try container.encode(MessageType.authFailed, forKey: .type)
            try container.encode(reason, forKey: .reason)
        case let .snapshot(snapshot, sessionName):
            try container.encode(MessageType.snapshot, forKey: .type)
            try container.encode(snapshot, forKey: .snapshot)
            try container.encodeIfPresent(sessionName, forKey: .sessionName)
        case let .event(event):
            try container.encode(MessageType.event, forKey: .type)
            try container.encode(event, forKey: .event)
        case let .paneFrame(paneID, bytesBase64, full, seq, cols, rows):
            try container.encode(MessageType.paneFrame, forKey: .type)
            try container.encode(paneID, forKey: .paneID)
            try container.encode(bytesBase64, forKey: .bytesBase64)
            try container.encode(full, forKey: .full)
            try container.encode(seq, forKey: .seq)
            try container.encodeIfPresent(cols, forKey: .cols)
            try container.encodeIfPresent(rows, forKey: .rows)
        case let .error(message):
            try container.encode(MessageType.error, forKey: .type)
            try container.encode(message, forKey: .message)
        }
    }
}
