import Foundation

public struct AgentStatusline: Equatable, Sendable {
    public let mode: String?
    public let effort: String?
    public let model: String?
    public let agentCount: Int?
    public let cwd: String?
    public let branch: String?

    public init(
        mode: String? = nil,
        effort: String? = nil,
        model: String? = nil,
        agentCount: Int? = nil,
        cwd: String? = nil,
        branch: String? = nil
    ) {
        self.mode = mode
        self.effort = effort
        self.model = model
        self.agentCount = agentCount
        self.cwd = cwd
        self.branch = branch
    }

    public var isEmpty: Bool {
        mode == nil && effort == nil && model == nil && agentCount == nil
            && cwd == nil && branch == nil
    }
}

public enum AgentStatuslineParser {
    private static let effortValues = ["low", "medium", "high", "xhigh", "max", "ultra"]
    private static let modeExpression = expression(
        #"(?:⏸\s*)?([A-Za-z][A-Za-z -]*?)\s+mode on"#
    )
    private static let agentsExpression = expression(#"←\s*(\d+)\s+agents?\b"#)
    private static let effortExpression = expression(
        #"(?:◉\s*)?(low|medium|high|xhigh|max|ultra)(?:\s+effort)?\b"#
    )
    private static let modelExpression = expression(#"\b(gpt-[A-Za-z0-9._-]+)\b"#)
    private static let branchExpression = expression(#"(?:branch|git)\s*[:=]\s*([^·│]+)"#)
    private static let claudeModelExpression = expression(
        #"(?:^|\s{2,})([A-Za-z][A-Za-z0-9 ._-]*?)\s+with\s+(?:low|medium|high|xhigh|max|ultra)\s+effort"#
    )
    private static let claudeEffortExpression = expression(
        #"\b(low|medium|high|xhigh|max|ultra)\s+effort\b"#
    )
    private static let claudePathExpression = expression(
        #"(?:^|\s{2,})((?:~?/).+)$"#
    )

    public static func parse(_ grid: String) -> AgentStatusline? {
        let lines = grid.components(separatedBy: .newlines)
            .map {
                $0.trimmingCharacters(
                    in: .whitespaces.union(CharacterSet(charactersIn: "│"))
                )
            }
        guard lines.contains(where: { !$0.isEmpty }) else { return nil }

        var mode: String?
        var effort: String?
        var model: String?
        var agentCount: Int?
        var cwd: String?
        var branch: String?
        var sawBottomStatus = false

        for line in lines.suffix(12) where !line.isEmpty {
            let agents = capture(agentsExpression, in: line)
            let claudeStatus = line.contains("/effort")
                || agents != nil
                || (line.contains("? for shortcuts") && line.contains("mode on"))
            let codexModel = capture(modelExpression, in: line)
            let codexStatus = codexModel != nil
                && (line.contains("·") || line.hasPrefix("model:"))

            if claudeStatus {
                if let value = capture(modeExpression, in: line) {
                    mode = value.lowercased()
                }
                if let agents {
                    agentCount = Int(agents)
                }
                if let value = capture(effortExpression, in: line) {
                    effort = value.lowercased()
                }
            }
            if codexStatus, let codexModel {
                model = codexModel
                if let value = capture(effortExpression, in: line) {
                    effort = value.lowercased()
                }
            }

            let segments = line.split(separator: "·").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if codexStatus, segments.count >= 2 {
                effort = segments.compactMap { segment in
                    effortValues.first { segment.lowercased() == $0 }
                }.first ?? effort
                if let path = segments.reversed().first(where: isPath) {
                    cwd = clean(path)
                }
            }
            sawBottomStatus = sawBottomStatus || claudeStatus || codexStatus
            if sawBottomStatus {
                if let value = capture(branchExpression, in: line) {
                    branch = clean(value)
                }
                if line.hasPrefix("directory:") {
                    cwd = clean(String(line.dropFirst("directory:".count)))
                } else if isPath(line) {
                    cwd = clean(line)
                }
            }
        }

        let header = Array(lines.prefix(6))
        if header.contains(where: { $0.contains("Claude Code") }) {
            for line in header where !line.isEmpty {
                if let value = capture(claudeModelExpression, in: line) {
                    model = clean(value)
                }
                if let value = capture(claudeEffortExpression, in: line) {
                    effort = effort ?? value.lowercased()
                }
                if let path = capture(claudePathExpression, in: line) {
                    cwd = cwd ?? clean(path)
                }
            }
        }
        if header.contains(where: { $0.contains("OpenAI Codex") }) {
            for line in header where !line.isEmpty {
                if let value = capture(modelExpression, in: line) {
                    model = value
                }
                if let value = capture(effortExpression, in: line) {
                    effort = value.lowercased()
                }
                if line.hasPrefix("directory:") {
                    cwd = clean(String(line.dropFirst("directory:".count)))
                }
            }
        }

        guard mode != nil || effort != nil || model != nil || agentCount != nil else {
            return nil
        }
        return AgentStatusline(
            mode: mode,
            effort: effort,
            model: model,
            agentCount: agentCount,
            cwd: cwd,
            branch: branch
        )
    }

    private static func expression(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static func capture(_ expression: NSRegularExpression, in value: String) -> String? {
        guard let match = expression.firstMatch(
                in: value,
                range: NSRange(value.startIndex..., in: value)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: value)
        else { return nil }
        return String(value[range])
    }

    private static func clean(_ value: String) -> String? {
        let cleaned = value.trimmingCharacters(
            in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "│╭╮╰╯"))
        )
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func isPath(_ value: String) -> Bool {
        let clean = value.trimmingCharacters(in: .whitespaces)
        return clean == "~" || clean.hasPrefix("~/") || clean.hasPrefix("/")
    }
}
