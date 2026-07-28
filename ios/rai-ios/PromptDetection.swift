import Foundation

struct PromptOption: Equatable, Identifiable {
    let digit: Int
    let label: String

    var id: Int { digit }
}

struct PromptModel: Equatable {
    let options: [PromptOption]
    let signature: String
}

enum PromptDetector {
    private static let optionExpression = try! NSRegularExpression(
        pattern: #"^\s*[❯>›]?\s*([1-9])[\.\)]\s+(.+?)\s*$"#
    )

    /// Detects only Claude Code's V1 single-choice permission and trust prompts.
    /// Input is rendered terminal-grid text, never an ANSI byte stream.
    static func detect(in gridText: String) -> PromptModel? {
        let lines = normalizedLines(gridText)
        var parsed: [(line: Int, option: PromptOption)] = []

        for (index, line) in lines.enumerated() {
            guard let option = parseOption(line) else { continue }
            parsed.append((index, option))
        }

        // Old numbered output often remains above a live prompt. Work from the
        // bottom and consider each compact option cluster independently.
        var clusters: [[(line: Int, option: PromptOption)]] = []
        for item in parsed {
            if let previous = clusters.last?.last, item.line - previous.line <= 2 {
                clusters[clusters.count - 1].append(item)
            } else {
                clusters.append([item])
            }
        }

        for cluster in clusters.reversed() {
            if let prompt = prompt(from: cluster, lines: lines) {
                return prompt
            }
        }
        return nil
    }

    private static func prompt(
        from parsed: [(line: Int, option: PromptOption)],
        lines: [String]
    ) -> PromptModel? {
        guard parsed.count >= 2,
              Set(parsed.map(\.option.digit)).count == parsed.count
        else { return nil }

        let first = parsed[0].line
        let last = parsed[parsed.count - 1].line
        let contextStart = max(0, first - 4)
        let contextEnd = min(lines.count - 1, last + 3)
        let region = Array(lines[contextStart...contextEnd])
        let context = region.joined(separator: "\n").lowercased()
        let labels = parsed.map(\.option.label).joined(separator: " ").lowercased()

        let hasPromptControls =
            (context.contains("enter") || context.contains("return"))
            && (context.contains("esc") || context.contains("cancel"))
        let isPermissionOrTrust =
            context.contains("permission")
            || context.contains("allow")
            || context.contains("approve")
            || context.contains("trust")
            || context.contains("proceed")
            || (labels.contains("yes") && labels.contains("no"))

        guard hasPromptControls, isPermissionOrTrust else { return nil }

        let signature = region
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        return PromptModel(options: parsed.map(\.option), signature: signature)
    }

    static func signatureMatches(_ expected: PromptModel, currentGridText: String) -> Bool {
        detect(in: currentGridText)?.signature == expected.signature
    }

    private static func parseOption(_ line: String) -> PromptOption? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = optionExpression.firstMatch(in: line, range: range),
              let digitRange = Range(match.range(at: 1), in: line),
              let labelRange = Range(match.range(at: 2), in: line),
              let digit = Int(line[digitRange])
        else { return nil }

        let label = line[labelRange]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return nil }
        return PromptOption(digit: digit, label: label)
    }

    private static func normalizedLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }
}
