import Foundation

public struct EndpointMetadataFragment: Equatable, Sendable {
    public let token: String
    public let text: String
    public let separator: String
    public let style: EndpointMetadataStyle
}

/// Resolves native sidebar rows from the complete, untruncated endpoint snapshot.
public enum EndpointMetadataResolver {
    public static func rows(record: JSONValue, kind: EndpointMetadataKind, snapshot: HerdrEndpointSnapshot,
                            configuration: EndpointMetadataConfiguration, machine: String? = nil) -> [[EndpointMetadataFragment]] {
        let object = record.objectValue ?? [:]
        let values = tokenValues(record: object, kind: kind, snapshot: snapshot, machine: machine)
        let layout = configuration[kind]
        let configuredRows = kind == .agent ? object["agent"]?.stringValue.flatMap { layout.rowsByAgent[$0] } ?? layout.rows : layout.rows
        return configuredRows.compactMap { row in
            var fragments: [EndpointMetadataFragment] = []
            for occurrence in row {
                guard let text = values[occurrence.token], !text.isEmpty else { continue }
                let separator = fragments.last.map { $0.token == "state_icon" || occurrence.token == "git_status" ? " " : " · " } ?? ""
                fragments.append(.init(token: occurrence.token, text: text, separator: separator,
                                       style: occurrence.resolvedStyle(for: text)))
            }
            return fragments.isEmpty ? nil : fragments
        }
    }

    public static func tokenValues(record: [String: JSONValue], kind: EndpointMetadataKind,
                                   snapshot: HerdrEndpointSnapshot, machine: String? = nil) -> [String: String] {
        var values = pairs(record["tokens"]).reduce(into: [String: String]()) { $0["$" + $1.key] = $1.value }
        let status = record["agent_status"]?.stringValue ?? "unknown"
        values["state_text"] = stateText(record)
        values["state_icon"] = ["working": "●", "blocked": "!", "done": "✓", "idle": "○", "unknown": "?"][status] ?? "?"
        if kind == .workspace {
            values["workspace"] = record["label"]?.stringValue
            values["branch"] = record["branch"]?.stringValue
            values["git_status"] = gitStatus(record["git_ahead_behind"])
        } else {
            resolveAgent(record, snapshot: snapshot, machine: machine, into: &values)
        }
        return values
    }

    public static func accessibilityLabel(record: JSONValue, rows: [[EndpointMetadataFragment]]) -> String {
        let fragments = rows.flatMap { $0 }
        let hasStateText = fragments.contains { $0.token == "state_text" }
        let status = stateText(record.objectValue ?? [:])
        return fragments.compactMap { fragment in
            if fragment.token == "state_icon" { return hasStateText ? nil : status }
            return fragment.text
        }.joined(separator: ", ")
    }

    private static func stateText(_ record: [String: JSONValue]) -> String {
        let status = record["agent_status"]?.stringValue ?? "unknown"
        return pairs(record["state_labels"])[status] ?? status
    }

    private static func resolveAgent(_ record: [String: JSONValue], snapshot: HerdrEndpointSnapshot,
                                     machine: String?, into values: inout [String: String]) {
        let workspace = matching(snapshot.workspaces, key: "workspace_id", value: record["workspace_id"])
        let tab = matching(snapshot.tabs, key: "tab_id", value: record["tab_id"])
        let pane = matching(snapshot.panes, key: "pane_id", value: record["pane_id"])
        let tabCount = snapshot.tabs.filter { $0.objectValue?["workspace_id"] == record["workspace_id"] }.count
        values["machine"] = machine
        values["workspace"] = workspace?["label"]?.stringValue
        if tabCount > 1 || tab?["custom_label"] == .bool(true) { values["tab"] = tab?["label"]?.stringValue }
        values["pane"] = record["title"]?.stringValue ?? pane?["label"]?.stringValue
        values["agent"] = ["display_agent", "name", "agent", "title"].compactMap { record[$0]?.stringValue }.first
        values["terminal_title"] = record["terminal_title"]?.stringValue
        values["terminal_title_stripped"] = record["terminal_title_stripped"]?.stringValue
    }

    private static func matching(_ records: [JSONValue], key: String, value: JSONValue?) -> [String: JSONValue]? {
        guard let value else { return nil }
        let matches = records.compactMap(\.objectValue).filter { $0[key] == value }
        return matches.count == 1 ? matches.first : nil
    }

    private static func pairs(_ raw: JSONValue?) -> [String: String] {
        guard case .array(let pairs) = raw else { return [:] }
        return pairs.reduce(into: [:]) { result, pair in
            guard case .array(let items) = pair, items.count == 2,
                  let key = items[0].stringValue, let value = items[1].stringValue else { return }
            result[key] = value
        }
    }

    private static func gitStatus(_ value: JSONValue?) -> String? {
        guard case .array(let pair) = value, pair.count == 2,
              let ahead = pair[0].numberValue, let behind = pair[1].numberValue,
              ahead.isFinite, behind.isFinite, ahead >= 0, behind >= 0,
              ahead.rounded() == ahead, behind.rounded() == behind else { return nil }
        return [(ahead, "↑"), (behind, "↓")].compactMap { number, prefix in
            number > 0 ? prefix + String(format: "%.0f", number) : nil
        }.joined(separator: " ")
    }
}
