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
    public static let minimumDecisionHoldSeconds = 5
    public static let defaultDecisionHoldSeconds = 45
    public static let maximumDecisionHoldSeconds = 60
    public static let hookReadGraceSeconds = 10
    public static let claudeTimeoutGraceSeconds = 15
    public static let events = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PermissionRequest",
        "Notification",
        "Stop",
    ]

    public static func merged(
        settings: Data?,
        scriptPath: String,
        decisionHoldSeconds: Int = defaultDecisionHoldSeconds
    ) throws -> Data {
        var root = try rootObject(from: settings)
        var hooks = try hooksObject(from: root)
        let holdSeconds = clampedDecisionHoldSeconds(decisionHoldSeconds)

        for event in events {
            var groups = try eventGroups(event, in: hooks)
            groups = removingManagedHandlers(
                from: groups,
                scriptPath: scriptPath,
                event: event
            )
            let command = hookCommand(
                scriptPath: scriptPath,
                event: event,
                decisionHoldSeconds: holdSeconds
            )
            var handler: [String: Any] = [
                "type": "command",
                "command": command,
                "timeout": event == "PermissionRequest"
                    ? holdSeconds + claudeTimeoutGraceSeconds
                    : 2,
            ]
            if event != "PermissionRequest" {
                handler["async"] = true
            }
            groups.append(["hooks": [handler]])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return try encoded(root)
    }

    public static func removing(settings: Data?, scriptPath: String) throws -> Data {
        var root = try rootObject(from: settings)
        var hooks = try hooksObject(from: root)

        for event in events {
            let groups = try eventGroups(event, in: hooks)
            var keptGroups: [[String: Any]] = []
            for var group in groups {
                guard let handlers = group["hooks"] as? [[String: Any]] else {
                    keptGroups.append(group)
                    continue
                }
                let keptHandlers = handlers.filter {
                    !isManagedHandler($0, scriptPath: scriptPath, event: event)
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

    public static func hookCommand(
        scriptPath: String,
        event: String,
        decisionHoldSeconds: Int = defaultDecisionHoldSeconds
    ) -> String {
        let base = "\(shellQuote(scriptPath)) \(event)"
        return event == "PermissionRequest"
            ? "\(base) \(clampedDecisionHoldSeconds(decisionHoldSeconds))"
            : base
    }

    public static func clampedDecisionHoldSeconds(_ value: Int) -> Int {
        min(max(value, minimumDecisionHoldSeconds), maximumDecisionHoldSeconds)
    }

    public static func hookReadTimeout(forHoldSeconds value: Int) -> Int {
        clampedDecisionHoldSeconds(value) + hookReadGraceSeconds
    }

    public static func claudeTimeout(forHoldSeconds value: Int) -> Int {
        clampedDecisionHoldSeconds(value) + claudeTimeoutGraceSeconds
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

    private static func removingManagedHandlers(
        from groups: [[String: Any]],
        scriptPath: String,
        event: String
    ) -> [[String: Any]] {
        groups.compactMap { group in
            guard let handlers = group["hooks"] as? [[String: Any]] else { return group }
            let kept = handlers.filter {
                !isManagedHandler($0, scriptPath: scriptPath, event: event)
            }
            guard !kept.isEmpty else { return nil }
            var updated = group
            updated["hooks"] = kept
            return updated
        }
    }

    private static func isManagedHandler(
        _ handler: [String: Any],
        scriptPath: String,
        event: String
    ) -> Bool {
        guard let command = handler["command"] as? String else { return false }
        let base = "\(shellQuote(scriptPath)) \(event)"
        return command == base || command.hasPrefix(base + " ")
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
