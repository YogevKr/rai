import Foundation

public enum ClaudeHookSettingsError: LocalizedError {
    case invalidRoot
    case invalidHooks
    case invalidEvent(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRoot:
            return "Claude settings must contain one JSON object."
        case .invalidHooks:
            return "The hooks setting must contain one JSON object."
        case let .invalidEvent(event):
            return "The \(event) hook setting must contain one JSON array."
        }
    }
}

/// Adds and removes only Rai-owned handlers in Claude Code user settings.
public enum ClaudeHookSettings {
    public static let events = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PermissionRequest",
        "Notification",
        "Stop",
    ]

    public static func merged(settings: Data?, scriptPath: String) throws -> Data {
        var root = try rootObject(from: settings)
        var hooks = try hooksObject(from: root)

        for event in events {
            var groups = try eventGroups(event, in: hooks)
            let command = hookCommand(scriptPath: scriptPath, event: event)
            guard !contains(command: command, in: groups) else { continue }
            groups.append([
                "matcher": "",
                "hooks": [[
                    "type": "command",
                    "command": command,
                    "async": true,
                    "timeout": 2,
                ]],
            ])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return try encoded(root)
    }

    public static func removing(settings: Data?, scriptPath: String) throws -> Data {
        var root = try rootObject(from: settings)
        var hooks = try hooksObject(from: root)

        for event in events {
            let command = hookCommand(scriptPath: scriptPath, event: event)
            let groups = try eventGroups(event, in: hooks)
            var keptGroups: [[String: Any]] = []
            for var group in groups {
                guard let handlers = group["hooks"] as? [[String: Any]] else {
                    keptGroups.append(group)
                    continue
                }
                let keptHandlers = handlers.filter {
                    ($0["command"] as? String) != command
                }
                if !keptHandlers.isEmpty {
                    group["hooks"] = keptHandlers
                    keptGroups.append(group)
                }
            }
            if keptGroups.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = keptGroups
            }
        }
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        return try encoded(root)
    }

    public static func hookCommand(scriptPath: String, event: String) -> String {
        "\(shellQuote(scriptPath)) \(event)"
    }

    private static func rootObject(from data: Data?) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeHookSettingsError.invalidRoot
        }
        return root
    }

    private static func hooksObject(from root: [String: Any]) throws -> [String: Any] {
        guard let raw = root["hooks"] else { return [:] }
        guard let hooks = raw as? [String: Any] else {
            throw ClaudeHookSettingsError.invalidHooks
        }
        return hooks
    }

    private static func eventGroups(
        _ event: String,
        in hooks: [String: Any]
    ) throws -> [[String: Any]] {
        guard let raw = hooks[event] else { return [] }
        guard let groups = raw as? [[String: Any]] else {
            throw ClaudeHookSettingsError.invalidEvent(event)
        }
        return groups
    }

    private static func contains(command: String, in groups: [[String: Any]]) -> Bool {
        groups.contains { group in
            guard let handlers = group["hooks"] as? [[String: Any]] else { return false }
            return handlers.contains { ($0["command"] as? String) == command }
        }
    }

    private static func encoded(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        data.append(0x0A)
        return data
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
