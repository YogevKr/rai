import Foundation

public enum TranscriptRole: String, Codable, Equatable, Sendable {
    case user
    case assistant
    case tool
}

public struct TranscriptTool: Codable, Equatable, Sendable {
    public let name: String
    public let summary: String

    public init(name: String, summary: String) {
        self.name = name
        self.summary = summary
    }
}

public struct TranscriptTurn: Codable, Equatable, Identifiable, Sendable {
    public let index: Int
    public let role: TranscriptRole
    public let text: String
    public let tool: TranscriptTool?
    public let timestamp: Date?
    public let truncated: Bool

    public var id: Int { index }

    public init(
        index: Int,
        role: TranscriptRole,
        text: String,
        tool: TranscriptTool? = nil,
        timestamp: Date? = nil,
        truncated: Bool = false
    ) {
        self.index = index
        self.role = role
        self.text = text
        self.tool = tool
        self.timestamp = timestamp
        self.truncated = truncated
    }

    enum CodingKeys: String, CodingKey {
        case index, role, text, tool, truncated
        case timestamp = "ts"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        role = try container.decode(TranscriptRole.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        tool = try container.decodeIfPresent(TranscriptTool.self, forKey: .tool)
        timestamp = try container.decodeIfPresent(TimeInterval.self, forKey: .timestamp)
            .map(Date.init(timeIntervalSince1970:))
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(index, forKey: .index)
        try container.encode(role, forKey: .role)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(tool, forKey: .tool)
        try container.encodeIfPresent(timestamp?.timeIntervalSince1970, forKey: .timestamp)
        try container.encode(truncated, forKey: .truncated)
    }
}

public struct TranscriptDocument: Equatable, Sendable {
    public let sessionID: String?
    public let turns: [TranscriptTurn]
    public let skippedRecordTypes: Set<String>

    public init(
        sessionID: String?,
        turns: [TranscriptTurn],
        skippedRecordTypes: Set<String>
    ) {
        self.sessionID = sessionID
        self.turns = turns
        self.skippedRecordTypes = skippedRecordTypes
    }
}

/// Parses Claude Code JSONL without requiring the final appended line to finish.
public enum TranscriptReader {
    public static let maximumSourceBytes = 32 * 1_024 * 1_024
    public static let maximumTurnTextBytes = 8_192
    public static let maximumToolResultBytes = 4_096
    public static let maximumToolSummaryBytes = 512

    public static func read(data: Data) -> TranscriptDocument {
        parse(data: data, stableIndexBase: nil)
    }

    public static func read(url: URL) throws -> TranscriptDocument {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        var start = size > UInt64(maximumSourceBytes)
            ? size - UInt64(maximumSourceBytes)
            : 0
        try handle.seek(toOffset: start)
        var data = try handle.read(upToCount: maximumSourceBytes) ?? Data()
        if start > 0 {
            guard let newline = data.firstIndex(of: 0x0A) else {
                return TranscriptDocument(sessionID: nil, turns: [], skippedRecordTypes: [])
            }
            let consumed = data.distance(from: data.startIndex, to: newline) + 1
            data.removeSubrange(data.startIndex...newline)
            start += UInt64(consumed)
        }
        guard start <= UInt64(Int.max - data.count) else {
            return TranscriptDocument(sessionID: nil, turns: [], skippedRecordTypes: [])
        }
        return parse(data: data, stableIndexBase: Int(start))
    }

    public static func read(text: String) -> TranscriptDocument {
        read(data: Data(text.utf8))
    }

    private static func parse(data: Data, stableIndexBase: Int?) -> TranscriptDocument {
        var sessionID: String?
        var turns: [TranscriptTurn] = []
        var skipped: Set<String> = []
        var byteOffset = 0
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let wholeSecondDateFormatter = ISO8601DateFormatter()
        wholeSecondDateFormatter.formatOptions = [.withInternetDateTime]

        for line in data.split(separator: 0x0A, omittingEmptySubsequences: false) {
            defer { byteOffset += line.count + 1 }
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let record = object as? [String: Any],
                  let type = record["type"] as? String else {
                continue
            }
            let firstNewTurn = turns.count
            sessionID = sessionID
                ?? record["sessionId"] as? String
                ?? record["session_id"] as? String
            let timestamp = (record["timestamp"] as? String).flatMap {
                dateFormatter.date(from: $0) ?? wholeSecondDateFormatter.date(from: $0)
            }
            guard record["isSidechain"] as? Bool != true else { continue }

            switch type {
            case "user":
                parseUser(record, timestamp: timestamp, into: &turns)
            case "assistant":
                parseAssistant(record, timestamp: timestamp, into: &turns)
            default:
                skipped.insert(type)
            }
            if let stableIndexBase {
                for index in firstNewTurn..<turns.count {
                    let turn = turns[index]
                    turns[index] = TranscriptTurn(
                        index: stableIndexBase + byteOffset + index - firstNewTurn,
                        role: turn.role,
                        text: turn.text,
                        tool: turn.tool,
                        timestamp: turn.timestamp,
                        truncated: turn.truncated
                    )
                }
            }
        }

        return TranscriptDocument(
            sessionID: sessionID,
            turns: stableIndexBase == nil ? turns.enumerated().map { offset, turn in
                TranscriptTurn(
                    index: offset,
                    role: turn.role,
                    text: turn.text,
                    tool: turn.tool,
                    timestamp: turn.timestamp,
                    truncated: turn.truncated
                )
            } : turns,
            skippedRecordTypes: skipped
        )
    }

    private static func parseUser(
        _ record: [String: Any],
        timestamp: Date?,
        into turns: inout [TranscriptTurn]
    ) {
        guard record["isMeta"] as? Bool != true,
              let message = record["message"] as? [String: Any] else { return }
        if let text = message["content"] as? String {
            guard !isInternalUserText(text), !text.isEmpty else { return }
            turns.append(turn(role: .user, text: text, timestamp: timestamp))
            return
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return }
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String,
                   !isInternalUserText(text), !text.isEmpty {
                    turns.append(turn(role: .user, text: text, timestamp: timestamp))
                }
            case "tool_result":
                let raw = contentText(block["content"])
                let bounded = bytePrefix(raw, limit: maximumToolResultBytes)
                turns.append(TranscriptTurn(
                    index: 0,
                    role: .tool,
                    text: bounded.text,
                    timestamp: timestamp,
                    truncated: bounded.truncated
                ))
            default:
                continue
            }
        }
    }

    private static func parseAssistant(
        _ record: [String: Any],
        timestamp: Date?,
        into turns: inout [TranscriptTurn]
    ) {
        guard let message = record["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else { return }
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty {
                    turns.append(turn(role: .assistant, text: text, timestamp: timestamp))
                }
            case "tool_use":
                guard let name = block["name"] as? String else { continue }
                let input = block["input"] as? [String: Any] ?? [:]
                let summary = toolSummary(input)
                turns.append(TranscriptTurn(
                    index: 0,
                    role: .assistant,
                    text: "",
                    tool: TranscriptTool(name: name, summary: summary.text),
                    timestamp: timestamp,
                    truncated: summary.truncated
                ))
            default:
                continue
            }
        }
    }

    private static func turn(
        role: TranscriptRole,
        text: String,
        timestamp: Date?
    ) -> TranscriptTurn {
        let bounded = bytePrefix(text, limit: maximumTurnTextBytes)
        return TranscriptTurn(
            index: 0,
            role: role,
            text: bounded.text,
            timestamp: timestamp,
            truncated: bounded.truncated
        )
    }

    private static func isInternalUserText(_ text: String) -> Bool {
        text.hasPrefix("<command-")
            || text.hasPrefix("<local-command-")
            || text.hasPrefix("<local-command-caveat>")
            || text.hasPrefix("<system-reminder>")
            || text.hasPrefix("<task-notification>")
    }

    private static func contentText(_ value: Any?) -> String {
        if let value = value as? String { return value }
        guard let blocks = value as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private static func toolSummary(
        _ input: [String: Any]
    ) -> (text: String, truncated: Bool) {
        let preferredKeys = [
            "command", "file_path", "notebook_path", "path", "url",
            "query", "pattern", "description", "prompt", "name",
        ]
        let raw = preferredKeys.lazy.compactMap { input[$0] as? String }.first ?? ""
        let oneLine = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return bytePrefix(oneLine, limit: maximumToolSummaryBytes)
    }

    static func bytePrefix(_ text: String, limit: Int) -> (text: String, truncated: Bool) {
        let data = Data(text.utf8)
        guard data.count > limit else { return (text, false) }
        var count = max(0, limit)
        while count > 0 {
            if let prefix = String(data: data.prefix(count), encoding: .utf8) {
                return (prefix, true)
            }
            count -= 1
        }
        return ("", true)
    }
}

public enum ClaudeTranscriptLocator {
    private static func isContained(_ candidate: URL, in root: URL) -> Bool {
        candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")
    }

    public static func beaconTranscript(
        path: String,
        sessionID: String,
        claudeDirectory: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let root = claudeDirectory.appendingPathComponent("projects", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let candidate = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        guard candidate.pathExtension == "jsonl",
              candidate.deletingPathExtension().lastPathComponent == sessionID,
              isContained(candidate, in: root),
              fileManager.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }
}

public enum TranscriptLookupResult: Sendable {
    case found(url: URL, document: TranscriptDocument)
    case notFound
    case hookRequired
}

/// Keeps transcript reads and pagination off the main actor.
public actor ClaudeTranscriptIndex {
    private let claudeDirectory: URL
    private var paneCache: [String: (beaconPath: String, sessionID: String, url: URL)] = [:]

    public init(claudeDirectory: URL) {
        self.claudeDirectory = claudeDirectory
    }

    public func read(
        paneID: String,
        beaconPath: String?,
        sessionID: String?
    ) -> TranscriptLookupResult {
        guard let beaconPath, let sessionID, !sessionID.isEmpty else {
            return .hookRequired
        }
        guard let resolved = ClaudeTranscriptLocator.beaconTranscript(
            path: beaconPath,
            sessionID: sessionID,
            claudeDirectory: claudeDirectory
        ) else { return .notFound }
        let url: URL
        if let cached = paneCache[paneID],
           cached.beaconPath == beaconPath,
           cached.sessionID == sessionID,
           cached.url == resolved {
            url = cached.url
        } else {
            url = resolved
        }
        guard let document = try? TranscriptReader.read(url: url),
              document.sessionID == sessionID else { return .notFound }
        paneCache[paneID] = (beaconPath, sessionID, url)
        return .found(url: url, document: document)
    }

    public func page(
        paneID: String,
        beaconPath: String?,
        sessionID: String?,
        requestedSessionID: String,
        requestID: String,
        herdSessionName: String?,
        beforeTurnIndex: Int?,
        limit: Int
    ) -> TranscriptHistoryPage {
        let lookup = read(
            paneID: paneID,
            beaconPath: beaconPath,
            sessionID: sessionID
        )
        let resolvedSessionID = sessionID ?? ""
        let turns: [TranscriptTurn]
        let state: TranscriptHistoryState
        switch lookup {
        case let .found(_, document):
            turns = document.turns
            state = .available
        case .notFound:
            turns = []
            state = .notFound
        case .hookRequired:
            turns = []
            state = .hookRequired
        }
        let page = TranscriptPagination.page(
            paneID: paneID,
            sessionID: resolvedSessionID,
            herdSessionName: herdSessionName,
            turns: turns,
            beforeTurnIndex: beforeTurnIndex,
            limit: limit
        )
        return TranscriptHistoryPage(
            paneID: paneID,
            sessionID: requestedSessionID,
            resolvedSessionID: resolvedSessionID,
            requestID: requestID,
            herdSessionName: page.herdSessionName,
            turns: page.turns,
            hasMore: page.hasMore,
            state: state
        )
    }

    public func invalidate(paneID: String) {
        paneCache.removeValue(forKey: paneID)
    }

    public func retainPanes(_ paneIDs: Set<String>) {
        paneCache = paneCache.filter { paneIDs.contains($0.key) }
    }
}

public struct TranscriptPaneIdentity: Equatable, Sendable {
    public let agent: String?
    public let sessionID: String?
    public let status: AgentStatus

    public init(agent: String?, sessionID: String?, status: AgentStatus) {
        self.agent = agent
        self.sessionID = sessionID
        self.status = status
    }

    public func requiresTranscriptResolution(after previous: Self) -> Bool {
        previous.agent != agent
            || previous.sessionID != sessionID
            || (previous.status != .working && status == .working)
    }
}

public struct HistoryDeliveryTracker<Device: Hashable, Connection: Hashable> {
    public static var defaultMaximumPanesPerDevice: Int { 64 }

    private struct Cursor {
        let sessionID: String
        let highestTurnIndex: Int
        var lastAccess: UInt64
    }

    private let maximumPanesPerDevice: Int
    private var lastDelivered: [Device: [String: Cursor]] = [:]
    private var deliveredPanes: [Connection: Set<String>] = [:]
    private var accessSequence: UInt64 = 0

    public init(maximumPanesPerDevice: Int = defaultMaximumPanesPerDevice) {
        self.maximumPanesPerDevice = max(1, maximumPanesPerDevice)
    }

    public mutating func sinceLastSeen(
        device: Device,
        connection: Connection,
        paneID: String,
        sessionID: String
    ) -> Int? {
        let key = paneID + "\u{1F}" + sessionID
        guard deliveredPanes[connection]?.contains(key) != true else { return nil }
        guard var cursor = lastDelivered[device]?[paneID],
              cursor.sessionID == sessionID else { return nil }
        cursor.lastAccess = nextAccess()
        lastDelivered[device]?[paneID] = cursor
        return cursor.highestTurnIndex
    }

    public mutating func recordDelivery(
        device: Device,
        connection: Connection,
        paneID: String,
        sessionID: String,
        highestTurnIndex: Int?
    ) {
        let key = paneID + "\u{1F}" + sessionID
        deliveredPanes[connection, default: []].insert(key)
        if let highestTurnIndex {
            var cursors = lastDelivered[device, default: [:]]
            let old = cursors[paneID]
            cursors[paneID] = Cursor(
                sessionID: sessionID,
                highestTurnIndex: old?.sessionID == sessionID
                    ? max(old?.highestTurnIndex ?? -1, highestTurnIndex)
                    : highestTurnIndex,
                lastAccess: nextAccess()
            )
            if cursors.count > maximumPanesPerDevice,
               let oldest = cursors.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
                cursors.removeValue(forKey: oldest)
            }
            lastDelivered[device] = cursors
        }
    }

    public mutating func removeConnection(_ connection: Connection) {
        deliveredPanes.removeValue(forKey: connection)
    }

    public mutating func removeDevice(_ device: Device) {
        lastDelivered.removeValue(forKey: device)
    }

    public func cursorCount(for device: Device) -> Int {
        lastDelivered[device]?.count ?? 0
    }

    private mutating func nextAccess() -> UInt64 {
        accessSequence &+= 1
        return accessSequence
    }
}

public struct HistoryPageReceipt: Hashable, Sendable {
    public let paneID: String
    public let sessionID: String
    public let requestID: String
    public let herdSessionName: String?
    public let throughTurnIndex: Int?

    public init(
        paneID: String,
        sessionID: String,
        requestID: String = "",
        herdSessionName: String? = nil,
        throughTurnIndex: Int?
    ) {
        self.paneID = paneID
        self.sessionID = sessionID
        self.requestID = requestID
        self.herdSessionName = herdSessionName
        self.throughTurnIndex = throughTurnIndex
    }
}

public struct HistoryReceiptLedger<Connection: Hashable> {
    public static var maximumPendingPerConnection: Int { 100 }

    private var pending: [Connection: [HistoryPageReceipt]] = [:]

    public init() {}

    public mutating func recordSent(_ receipt: HistoryPageReceipt, connection: Connection) {
        var receipts = pending[connection, default: []]
        if !receipts.contains(receipt) { receipts.append(receipt) }
        if receipts.count > Self.maximumPendingPerConnection {
            receipts.removeFirst(receipts.count - Self.maximumPendingPerConnection)
        }
        pending[connection] = receipts
    }

    public mutating func acknowledge(
        _ receipt: HistoryPageReceipt,
        connection: Connection
    ) -> Bool {
        guard let index = pending[connection]?.firstIndex(of: receipt) else { return false }
        pending[connection]?.remove(at: index)
        if pending[connection]?.isEmpty == true { pending.removeValue(forKey: connection) }
        return true
    }

    public mutating func removeConnection(_ connection: Connection) {
        pending.removeValue(forKey: connection)
    }
}
