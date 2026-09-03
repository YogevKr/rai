import Foundation

/// One Claude Code lifecycle report received from rai's local hook socket.
///
/// `toolInput` is reduced during decoding. A hook can contain file content or
/// another large value, but bridge snapshots and notifications must stay small.
public struct AgentBeacon: Codable, Equatable, Sendable {
    public static let maximumToolInputBytes = 16_384
    public static let maximumMessageBytes = 16_384

    public let event: String
    public let paneID: String?
    public let herdrSocketPath: String?
    public let sessionID: String
    public let cwd: String
    public let transcriptPath: String
    public let toolName: String?
    public let toolInput: JSONValue?
    public let requestID: String?
    public let notificationType: String?
    public let message: String?
    public let lastAssistantMessage: String?
    public let timestamp: TimeInterval
    public let parentPID: Int?

    public init(
        event: String,
        paneID: String? = nil,
        herdrSocketPath: String? = nil,
        sessionID: String,
        cwd: String,
        transcriptPath: String,
        toolName: String? = nil,
        toolInput: JSONValue? = nil,
        requestID: String? = nil,
        notificationType: String? = nil,
        message: String? = nil,
        lastAssistantMessage: String? = nil,
        timestamp: TimeInterval,
        parentPID: Int? = nil
    ) {
        self.event = event
        self.paneID = paneID
        self.herdrSocketPath = herdrSocketPath
        self.sessionID = sessionID
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.toolName = toolName
        self.toolInput = Self.bounded(toolInput)
        self.requestID = requestID
        self.notificationType = notificationType
        self.message = Self.boundedPrefix(message)
        self.lastAssistantMessage = Self.boundedSuffix(lastAssistantMessage)
        self.timestamp = timestamp
        self.parentPID = parentPID
    }

    enum CodingKeys: String, CodingKey {
        case event
        case paneID = "pane_id"
        case herdrSocketPath = "herdr_socket_path"
        case sessionID = "session_id"
        case cwd
        case transcriptPath = "transcript_path"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case requestID = "request_id"
        case notificationType = "notification_type"
        case message
        case lastAssistantMessage = "last_assistant_message"
        case timestamp = "ts"
        case parentPID = "parent_pid"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        event = try container.decode(String.self, forKey: .event)
        paneID = try container.decodeIfPresent(String.self, forKey: .paneID)
        herdrSocketPath = try container.decodeIfPresent(
            String.self,
            forKey: .herdrSocketPath
        )
        sessionID = try container.decode(String.self, forKey: .sessionID)
        cwd = try container.decode(String.self, forKey: .cwd)
        transcriptPath = try container.decode(String.self, forKey: .transcriptPath)
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        toolInput = Self.bounded(
            try container.decodeIfPresent(JSONValue.self, forKey: .toolInput)
        )
        requestID = try container.decodeIfPresent(String.self, forKey: .requestID)
        notificationType = try container.decodeIfPresent(
            String.self,
            forKey: .notificationType
        )
        message = Self.boundedPrefix(
            try container.decodeIfPresent(String.self, forKey: .message)
        )
        lastAssistantMessage = Self.boundedSuffix(
            try container.decodeIfPresent(String.self, forKey: .lastAssistantMessage)
        )
        timestamp = try container.decode(TimeInterval.self, forKey: .timestamp)
        parentPID = try container.decodeIfPresent(Int.self, forKey: .parentPID)
    }

    /// Adds tool data from the preceding PreToolUse or PermissionRequest event.
    /// Notification payloads identify a permission prompt but omit its tool.
    public func inheritingTool(from previous: AgentBeacon?) -> AgentBeacon {
        guard event == "Notification",
              notificationType == "permission_prompt",
              toolName == nil,
              let previous,
              previous.sessionID == sessionID else {
            return self
        }
        return AgentBeacon(
            event: event,
            paneID: paneID ?? previous.paneID,
            herdrSocketPath: herdrSocketPath ?? previous.herdrSocketPath,
            sessionID: sessionID,
            cwd: cwd,
            transcriptPath: transcriptPath,
            toolName: previous.toolName,
            toolInput: previous.toolInput,
            requestID: requestID ?? previous.requestID,
            notificationType: notificationType,
            message: message,
            lastAssistantMessage: lastAssistantMessage,
            timestamp: timestamp,
            parentPID: parentPID ?? previous.parentPID
        )
    }

    /// Text for a blocked row or notification. Other lifecycle events return nil.
    public var pendingSummary: String? {
        if event == "PreToolUse", toolName == "AskUserQuestion" {
            return firstQuestion
        }
        guard event == "PermissionRequest"
                || (event == "Notification" && notificationType == "permission_prompt")
        else { return nil }
        guard let toolName else { return oneLine(message) }
        guard let detail = toolDetail else { return toolName }
        return Self.oneLine("\(toolName): \(detail)")
    }

    public var completionSummary: String? {
        guard event == "Stop", let lastAssistantMessage else { return nil }
        return lastAssistantMessage
            .split(whereSeparator: \.isNewline)
            .reversed()
            .compactMap { Self.oneLine(String($0)) }
            .first
    }

    private var firstQuestion: String? {
        guard case let .object(input)? = toolInput,
              case let .array(questions)? = input["questions"],
              case let .object(first)? = questions.first,
              case let .string(question)? = first["question"] else {
            return nil
        }
        return Self.oneLine(question)
    }

    private var toolDetail: String? {
        guard case let .object(input)? = toolInput else { return nil }
        if toolName == "Bash" {
            if case let .string(command)? = input["command"] {
                return Self.safeBashSummary(command)
            }
            if case let .string(description)? = input["description"] {
                return Self.oneLine(description)
            }
            return nil
        }
        if toolName == "WebFetch" {
            guard case let .string(url)? = input["url"] else { return nil }
            return Self.safeURLSummary(url)
        }
        let preferredKeys: [String]
        switch toolName {
        case "Read", "Write", "Edit", "NotebookEdit":
            preferredKeys = ["file_path", "notebook_path", "path"]
        case "WebSearch":
            preferredKeys = ["query"]
        default:
            preferredKeys = ["command", "file_path", "path", "url", "query", "description"]
        }
        for key in preferredKeys {
            if case let .string(value)? = input[key], let summary = Self.oneLine(value) {
                return summary
            }
        }
        return nil
    }

    private static func safeURLSummary(_ rawURL: String) -> String? {
        guard let input = URLComponents(string: rawURL),
              let scheme = input.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = input.host else {
            return "remote URL"
        }
        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        origin.port = input.port
        guard var summary = origin.string else { return "remote URL" }
        if !input.path.isEmpty, input.path != "/" { summary += "/…" }
        return summary
    }

    private static func safeBashSummary(_ rawCommand: String) -> String? {
        guard let command = oneLine(rawCommand) else { return nil }
        let tokens = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = tokens.first else { return nil }
        let executable = URL(fileURLWithPath: first).lastPathComponent
        guard executable.range(
            of: #"^[A-Za-z0-9_.+-]+$"#,
            options: .regularExpression
        ) != nil else {
            return "shell command"
        }
        guard command.rangeOfCharacter(from: CharacterSet(charactersIn: ";|&><")) == nil
        else { return tokens.count == 1 ? executable : "\(executable) …" }

        let second = tokens.count > 1 ? tokens[1] : nil
        let safeSecond: [String: Set<String>] = [
            "swift": ["build", "test", "package"],
            "git": ["status", "diff", "log", "show", "branch"],
            "cargo": ["build", "test", "check", "fmt", "clippy"],
            "go": ["build", "test", "fmt", "vet"],
        ]
        if let second, safeSecond[executable]?.contains(second) == true {
            return "\(executable) \(second)"
        }
        if ["npm", "pnpm", "yarn", "bun"].contains(executable), let second {
            if second == "run", tokens.count > 2,
               tokens[2].range(
                   of: #"^[A-Za-z0-9_.:-]+$"#,
                   options: .regularExpression
               ) != nil {
                return "\(executable) run \(tokens[2])"
            }
            if ["test", "build"].contains(second) {
                return "\(executable) \(second)"
            }
        }
        if executable == "make", let second,
           second.range(
               of: #"^[A-Za-z0-9_.:-]+$"#,
               options: .regularExpression
           ) != nil {
            return "make \(second)"
        }
        return tokens.count == 1 ? executable : "\(executable) …"
    }

    private func oneLine(_ value: String?) -> String? {
        value.flatMap(Self.oneLine)
    }

    private static func oneLine(_ value: String) -> String? {
        let words = value.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        let joined = words.joined(separator: " ")
        guard joined.count > 240 else { return joined }
        return String(joined.prefix(237)) + "…"
    }

    private static func bounded(_ value: JSONValue?) -> JSONValue? {
        guard let value else { return nil }
        var budget = 12_000
        let reduced = reduce(value, depth: 0, budget: &budget)
        guard let data = try? JSONEncoder().encode(reduced),
              data.count <= maximumToolInputBytes else {
            return .object(["_truncated": .bool(true)])
        }
        return reduced
    }

    private static func boundedPrefix(_ value: String?) -> String? {
        guard let value, value.utf8.count > maximumMessageBytes else { return value }
        return String(decoding: value.utf8.prefix(maximumMessageBytes - 6), as: UTF8.self)
            + "…"
    }

    private static func boundedSuffix(_ value: String?) -> String? {
        guard let value, value.utf8.count > maximumMessageBytes else { return value }
        return "…" + String(
            decoding: value.utf8.suffix(maximumMessageBytes - 6),
            as: UTF8.self
        )
    }

    private static func reduce(
        _ value: JSONValue,
        depth: Int,
        budget: inout Int
    ) -> JSONValue {
        guard depth < 8, budget > 0 else {
            return .string("…")
        }
        switch value {
        case .null, .bool, .number:
            budget -= 8
            return value
        case let .string(string):
            let bytes = string.utf8.prefix(min(budget, 4_096))
            var reduced = String(decoding: bytes, as: UTF8.self)
            if bytes.count < string.utf8.count { reduced += "…" }
            budget -= bytes.count
            return .string(reduced)
        case let .array(values):
            return .array(values.prefix(24).map {
                reduce($0, depth: depth + 1, budget: &budget)
            })
        case let .object(values):
            let priority = [
                "command", "file_path", "notebook_path", "path", "url",
                "query", "questions", "question", "description", "options",
                "label", "header", "multiSelect",
            ]
            let keys = values.keys.sorted {
                let lhs = priority.firstIndex(of: $0) ?? priority.count
                let rhs = priority.firstIndex(of: $1) ?? priority.count
                return lhs == rhs ? $0 < $1 : lhs < rhs
            }
            var object: [String: JSONValue] = [:]
            for key in keys.prefix(32) where budget > 0 {
                budget -= min(key.utf8.count, 128)
                object[key] = reduce(values[key]!, depth: depth + 1, budget: &budget)
            }
            if keys.count > object.count || budget <= 0 {
                object["_truncated"] = .bool(true)
            }
            return .object(object)
        }
    }
}

public enum AgentNotificationBody {
    public static func compose(status: AgentStatus, beacon: AgentBeacon?) -> String {
        let body = switch status {
        case .blocked:
            beacon?.pendingSummary ?? "Needs you"
        case .done:
            beacon?.completionSummary ?? "Finished"
        default:
            status == .working ? "Working" : "Idle"
        }
        return redactingSecrets(in: body, isCompletion: status == .done)
    }

    private static func redactingSecrets(
        in value: String,
        isCompletion: Bool
    ) -> String {
        if value.range(
            of: #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
            options: .regularExpression
        ) != nil {
            return "Sensitive request details redacted"
        }
        let patterns = [
            #"(?i)(\b(?:proxy-)?authorization\s*:\s*(?:basic|bearer)\s+)[A-Za-z0-9._~+/=-]{4,}"#,
            #"(?i)(\bbearer\s+)[A-Za-z0-9._~+/=-]{8,}"#,
            #"(?i)(\b(?:sk-(?:proj-)?|gh[pousr]_))[A-Za-z0-9_-]{8,}"#,
            #"([?&][^=&#\s]+\s*=\s*)[^&#\s]+"#,
            #"(?i)(https?://[^\s#]+#)[^\s]+"#,
            #"(?i)(://)[^/@\s]+:[^/@\s]+@"#,
            #"(?i)(\b(?:cookie|set-cookie)\s*:\s*)[^'"\s]+"#,
            #"(?i)(\b[A-Z0-9_]*(?:token|secret|password|passwd|session|cookie|api[_-]?key|private[_-]?key|credential)[A-Z0-9_]*\b\s*[:=]\s*)[^\s,;&]+"#,
            #"(?i)(\s(?:-H|--header)\s+['"]?[^:'"\s]+:\s*)[^'"\s]+"#,
            #"(?i)(--?(?:password|token|secret|api[_-]?key)\s+)[^\s]+"#,
            #"(?i)(\s(?:-u|--user)\s+)[^\s]+"#,
            #"(?i)(\s(?:-b|--cookie)\s+)[^\s]+"#,
            #"(?i)(\s(?:-d|--data(?:-raw|-binary|-urlencode)?)\s+)[^\s]+"#,
            #"((?:^|\s)[A-Za-z_][A-Za-z0-9_]*=)[^\s]+"#,
            #"(?i)\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#,
            #"\b(?:AKIA|ASIA|AIDA|AROA|AIPA|ANPA|ANVA|ASCA)[A-Z0-9]{16}\b"#,
            #"\bAIza[A-Za-z0-9_-]{20,}\b"#,
            #"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"#,
            #"\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{10,}\b"#,
        ]
        let redacted = patterns.reduce(value) { result, pattern in
            guard let expression = try? NSRegularExpression(pattern: pattern) else {
                return result
            }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            return expression.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: pattern.hasPrefix(#"(?i)\beyJ"#)
                    || pattern.hasPrefix(#"\b(?:AKIA"#)
                    || pattern.hasPrefix(#"\bAIza"#)
                    || pattern.hasPrefix(#"\bxox"#)
                    || pattern.hasPrefix(#"\b(?:sk|rk)"#)
                    ? "<redacted>"
                    : "$1<redacted>"
            )
        }
        guard isCompletion else { return redacted }

        let sensitivePhrase = try? NSRegularExpression(
            pattern: #"(?i)\b(?:password|passwd|passcode|credential|cookie|secret|private[ _-]?key|api[ _-]?key|access[ _-]?key|auth(?:entication)?[ _-]?(?:key|token)|session[ _-]?(?:key|token))\b"#
        )
        let redactedRange = NSRange(redacted.startIndex..<redacted.endIndex, in: redacted)
        if sensitivePhrase?.firstMatch(in: redacted, range: redactedRange) != nil {
            return "Sensitive completion details redacted"
        }

        let opaqueCredential = try? NSRegularExpression(
            pattern: #"(?=[A-Za-z0-9_+/=-]{24,}\b)(?=[A-Za-z0-9_+/=-]*[A-Za-z])(?=[A-Za-z0-9_+/=-]*[0-9])[A-Za-z0-9_+/=-]{24,}"#
        )
        if opaqueCredential?.firstMatch(in: redacted, range: redactedRange) != nil {
            return "Sensitive completion details redacted"
        }
        return redacted
    }
}

public struct BeaconPaneCandidate: Equatable, Sendable {
    public let paneID: String
    public let cwd: String
    public let shellPID: Int?
    public let processIDs: Set<Int>

    public init(
        paneID: String,
        cwd: String,
        shellPID: Int? = nil,
        processIDs: Set<Int> = []
    ) {
        self.paneID = paneID
        self.cwd = cwd
        self.shellPID = shellPID
        self.processIDs = processIDs
    }
}

public enum AgentBeaconCorrelator {
    public static func paneID(
        for beacon: AgentBeacon,
        candidates: [BeaconPaneCandidate],
        parentChain: [Int] = []
    ) -> String? {
        if let direct = beacon.paneID,
           candidates.contains(where: { $0.paneID == direct }) {
            return direct
        }

        let cwdMatches = candidates.filter {
            normalizedPath($0.cwd) == normalizedPath(beacon.cwd)
        }
        if cwdMatches.count == 1, parentChain.isEmpty {
            return cwdMatches[0].paneID
        }

        let pool = cwdMatches.isEmpty ? candidates : cwdMatches
        let ancestry = Set(parentChain)
        let processMatches = pool.filter { candidate in
            if let shellPID = candidate.shellPID, ancestry.contains(shellPID) {
                return true
            }
            return !ancestry.isDisjoint(with: candidate.processIDs)
        }
        return processMatches.count == 1 ? processMatches[0].paneID : nil
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}
