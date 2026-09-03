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
    public static let defaultMaximumAge: TimeInterval = 24 * 60 * 60

    /// The lab kept ASCII letters and numbers and mapped tested separators to hyphens.
    public static func projectDirectoryName(for cwd: String) -> String {
        String(cwd.unicodeScalars.map { scalar in
            let value = scalar.value
            let isASCIIAlphaNumeric = (48...57).contains(value)
                || (65...90).contains(value)
                || (97...122).contains(value)
            return isASCIIAlphaNumeric ? Character(String(scalar)) : "-"
        })
    }

    public static func newestTranscript(
        cwd: String,
        claudeDirectory: URL,
        sessionID: String? = nil,
        now: Date = Date(),
        maximumAge: TimeInterval = defaultMaximumAge,
        fileManager: FileManager = .default
    ) -> URL? {
        let rawURL = URL(fileURLWithPath: cwd).standardizedFileURL
        let resolvedURL = rawURL.resolvingSymlinksInPath()
        let paths = Array(Set([rawURL.path, resolvedURL.path]))
        let candidates = paths.flatMap { path -> [URL] in
            let directory = claudeDirectory
                .appendingPathComponent("projects", isDirectory: true)
                .appendingPathComponent(projectDirectoryName(for: path), isDirectory: true)
            return (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        }
        return candidates.compactMap { url -> (URL, Date)? in
            guard url.pathExtension == "jsonl",
                  sessionID.map({ url.deletingPathExtension().lastPathComponent == $0 }) ?? true,
                  let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]
                  ),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  sessionID != nil || (
                    now.timeIntervalSince(modified) >= 0
                        && now.timeIntervalSince(modified) <= maximumAge
                  ) else { return nil }
            return (url, modified)
        }
        .max { $0.1 < $1.1 }?.0
    }

    public static func beaconTranscript(
        path: String,
        claudeDirectory: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let root = claudeDirectory.appendingPathComponent("projects", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let candidate = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        guard candidate.pathExtension == "jsonl",
              candidate.path.hasPrefix(root.path + "/"),
              fileManager.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }

    public static func resolve(
        beaconPath: String?,
        cwd: String,
        claudeDirectory: URL,
        sessionID: String? = nil,
        now: Date = Date(),
        maximumAge: TimeInterval = defaultMaximumAge,
        fileManager: FileManager = .default
    ) -> URL? {
        if let beaconPath,
           let beacon = beaconTranscript(
               path: beaconPath,
               claudeDirectory: claudeDirectory,
               fileManager: fileManager
           ) {
            return beacon
        }
        return newestTranscript(
            cwd: cwd,
            claudeDirectory: claudeDirectory,
            sessionID: sessionID,
            now: now,
            maximumAge: maximumAge,
            fileManager: fileManager
        )
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
    private var lastDelivered: [Device: [String: Int]] = [:]
    private var deliveredPanes: [Connection: Set<String>] = [:]

    public init() {}

    public func sinceLastSeen(
        device: Device,
        connection: Connection,
        paneID: String,
        sessionID: String
    ) -> Int? {
        let key = paneID + "\u{1F}" + sessionID
        guard deliveredPanes[connection]?.contains(key) != true else { return nil }
        return lastDelivered[device]?[key]
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
            let old = lastDelivered[device]?[key] ?? -1
            lastDelivered[device, default: [:]][key] = max(old, highestTurnIndex)
        }
    }

    public mutating func removeConnection(_ connection: Connection) {
        deliveredPanes.removeValue(forKey: connection)
    }

    public mutating func removeDevice(_ device: Device) {
        lastDelivered.removeValue(forKey: device)
    }
}

public struct HistoryPageReceipt: Hashable, Sendable {
    public let paneID: String
    public let sessionID: String
    public let herdSessionName: String?
    public let throughTurnIndex: Int?

    public init(
        paneID: String,
        sessionID: String,
        herdSessionName: String? = nil,
        throughTurnIndex: Int?
    ) {
        self.paneID = paneID
        self.sessionID = sessionID
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
