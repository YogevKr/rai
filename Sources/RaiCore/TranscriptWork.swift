import Foundation

/// Async work a Claude Code session has in flight, recovered from its
/// transcript. Complements process-based detection (`BackgroundWorkParser`):
/// subagents and workflows run *inside* the claude process — no child process
/// to observe — but their lifecycle is fully recorded in the transcript:
///
/// - Start: a `tool_use` of Bash(run_in_background) / Agent / Workflow /
///   Monitor, whose `tool_result` confirms a background launch.
/// - End: a `<task-notification>` block carrying the same `<tool-use-id>`
///   (any status — completed, failed, or stopped all end the wait).
public struct PendingAsyncWork: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        case shell, monitor, subagent, workflow
    }

    public let kind: Kind
    public let toolUseID: String
    public let description: String
    public var id: String { toolUseID }

    public init(kind: Kind, toolUseID: String, description: String) {
        self.kind = kind
        self.toolUseID = toolUseID
        self.description = description
    }
}

public enum TranscriptWorkParser {
    /// Scans transcript JSONL lines (oldest→newest) and returns still-pending
    /// async work. Lines that don't parse are skipped; a truncated tail is
    /// fine — a completion whose start fell outside the window simply never
    /// surfaces as pending.
    public static func pendingAsyncWork(jsonlLines: [Substring]) -> [PendingAsyncWork] {
        var candidates: [String: PendingAsyncWork] = [:]   // toolUseID → work
        var launched: Set<String> = []
        var completed: Set<String> = []

        for line in jsonlLines {
            // Cheap prefilters before JSON parsing.
            let hasToolUse = line.contains("\"tool_use\"")
            let hasResult = line.contains("\"tool_result\"")
            let hasNotification = line.contains("task-notification")
            guard hasToolUse || hasResult || hasNotification else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) else {
                continue
            }
            walk(object) { dict in
                if dict["type"] as? String == "tool_use",
                   let name = dict["name"] as? String,
                   let id = dict["id"] as? String,
                   let input = dict["input"] as? [String: Any] {
                    switch name {
                    case "Bash" where input["run_in_background"] as? Bool == true:
                        candidates[id] = PendingAsyncWork(
                            kind: .shell, toolUseID: id,
                            description: input["description"] as? String
                                ?? firstLine(input["command"] as? String)
                        )
                    case "Monitor":
                        candidates[id] = PendingAsyncWork(
                            kind: .monitor, toolUseID: id,
                            description: input["description"] as? String
                                ?? firstLine(input["command"] as? String)
                        )
                    case "Agent", "Task":
                        candidates[id] = PendingAsyncWork(
                            kind: .subagent, toolUseID: id,
                            description: input["description"] as? String
                                ?? firstLine(input["prompt"] as? String)
                        )
                    case "Workflow":
                        candidates[id] = PendingAsyncWork(
                            kind: .workflow, toolUseID: id,
                            description: input["name"] as? String ?? "workflow"
                        )
                    default:
                        break
                    }
                }
                if dict["type"] as? String == "tool_result",
                   let id = dict["tool_use_id"] as? String,
                   candidates[id] != nil {
                    let text = resultText(dict)
                    switch candidates[id]!.kind {
                    case .shell where text.contains("Command running in background"),
                         .monitor,
                         .subagent where text.contains("Async agent launched"),
                         .workflow where !text.lowercased().contains("error"):
                        launched.insert(id)
                    default:
                        // A real (synchronous) result: the work already ended.
                        completed.insert(id)
                    }
                }
            }
            if hasNotification {
                // <tool-use-id>toolu_xxx</tool-use-id> inside the notification
                var search = line[...]
                while let open = search.range(of: "<tool-use-id>") {
                    guard let close = search.range(of: "</tool-use-id>"),
                          close.lowerBound > open.upperBound else { break }
                    completed.insert(String(search[open.upperBound..<close.lowerBound]))
                    search = search[close.upperBound...]
                }
            }
        }

        return candidates.values
            .filter { launched.contains($0.toolUseID) && !completed.contains($0.toolUseID) }
            .sorted { $0.toolUseID < $1.toolUseID }
    }

    private static func walk(_ object: Any, _ visit: ([String: Any]) -> Void) {
        if let dict = object as? [String: Any] {
            visit(dict)
            for value in dict.values { walk(value, visit) }
        } else if let array = object as? [Any] {
            for value in array { walk(value, visit) }
        }
    }

    private static func resultText(_ dict: [String: Any]) -> String {
        if let text = dict["content"] as? String { return text }
        guard let content = dict["content"] as? [Any] else { return "" }
        return content.compactMap { ($0 as? [String: Any])?["text"] as? String }
            .joined(separator: "\n")
    }

    private static func firstLine(_ text: String?) -> String {
        guard let text else { return "" }
        return text.split(separator: "\n").first.map(String.init) ?? text
    }
}
