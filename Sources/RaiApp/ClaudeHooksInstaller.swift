import Foundation
import RaiCore

enum ClaudeHooksAction: String {
    case install = "Install"
    case remove = "Remove"
}

struct ClaudeHooksPreview: Identifiable {
    let id = UUID()
    let action: ClaudeHooksAction
    let settingsURL: URL
    let scriptURL: URL
    let originalSettings: Data?
    let updatedSettings: Data
    let scriptData: Data?

    var text: String {
        String(decoding: updatedSettings, as: UTF8.self)
    }
}

enum ClaudeHooksInstallerError: LocalizedError {
    case linkedSettings
    case missingBundledScript
    case settingsChanged

    var errorDescription: String? {
        switch self {
        case .linkedSettings:
            return "Claude settings is a symbolic link. Select its target file instead."
        case .missingBundledScript:
            return "Rai cannot find its Claude hook script."
        case .settingsChanged:
            return "Claude settings changed after the preview. Open a new preview."
        }
    }
}

enum ClaudeHooksInstaller {
    private static let managedSettingsPathsKey = "claudeHookManagedSettingsPaths"

    static func hasManagedHooks(userDefaults: UserDefaults = .standard) -> Bool {
        !(userDefaults.stringArray(forKey: managedSettingsPathsKey) ?? []).isEmpty
    }

    static var defaultSettingsURL: URL {
        settingsURL(
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    static func settingsURL(
        environment: [String: String],
        homeDirectory: URL
    ) -> URL {
        let configured = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let directory = configured.flatMap { $0.isEmpty ? nil : $0 }
            .map { NSString(string: $0).expandingTildeInPath }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        return directory
            .appendingPathComponent("settings.json")
    }

    static var defaultScriptURL: URL {
        HookBeaconReceiver.defaultSocketURL
            .deletingLastPathComponent()
            .appendingPathComponent("rai-hook.sh")
    }

    static func makePreview(
        action: ClaudeHooksAction,
        settingsURL: URL = defaultSettingsURL,
        scriptURL: URL = defaultScriptURL,
        bundledScriptURL: URL? = bundledScriptURL,
        decisionHoldSeconds: Int = ClaudeHookSettings.defaultDecisionHoldSeconds
    ) throws -> ClaudeHooksPreview {
        try rejectSymbolicLink(at: settingsURL)
        let original = try existingData(at: settingsURL)
        let updated: Data
        let scriptData: Data?
        switch action {
        case .install:
            guard let bundledScriptURL else {
                throw ClaudeHooksInstallerError.missingBundledScript
            }
            scriptData = try Data(contentsOf: bundledScriptURL)
            updated = try ClaudeHookSettings.merged(
                settings: original,
                scriptPath: scriptURL.path,
                decisionHoldSeconds: decisionHoldSeconds
            )
        case .remove:
            scriptData = nil
            updated = try ClaudeHookSettings.removing(
                settings: original,
                scriptPath: scriptURL.path
            )
        }
        return ClaudeHooksPreview(
            action: action,
            settingsURL: settingsURL,
            scriptURL: scriptURL,
            originalSettings: original,
            updatedSettings: updated,
            scriptData: scriptData
        )
    }

    static func apply(
        _ preview: ClaudeHooksPreview,
        userDefaults: UserDefaults = .standard
    ) throws {
        try rejectSymbolicLink(at: preview.settingsURL)
        let current = try existingData(at: preview.settingsURL)
        guard current == preview.originalSettings else {
            throw ClaudeHooksInstallerError.settingsChanged
        }

        if preview.action == .install, let scriptData = preview.scriptData {
            let directory = preview.scriptURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try scriptData.write(to: preview.scriptURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: preview.scriptURL.path
            )
        }

        if preview.action == .remove, preview.originalSettings == nil {
            record(preview.action, settingsURL: preview.settingsURL, in: userDefaults)
            return
        }

        let settingsDirectory = preview.settingsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: settingsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if current != nil {
            let backupURL = preview.settingsURL.appendingPathExtension("bak")
            if FileManager.default.fileExists(atPath: backupURL.path) {
                try FileManager.default.removeItem(at: backupURL)
            }
            try FileManager.default.copyItem(at: preview.settingsURL, to: backupURL)
        }
        try preview.updatedSettings.write(to: preview.settingsURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: preview.settingsURL.path
        )
        record(preview.action, settingsURL: preview.settingsURL, in: userDefaults)
    }

    private static var bundledScriptURL: URL? {
        if let bundled = Bundle.main.url(forResource: "rai-hook", withExtension: "sh") {
            return bundled
        }
        let repositoryCopy = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/rai-hook.sh")
        return FileManager.default.fileExists(atPath: repositoryCopy.path)
            ? repositoryCopy
            : nil
    }

    private static func existingData(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    private static func rejectSymbolicLink(at url: URL) throws {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
            throw ClaudeHooksInstallerError.linkedSettings
        }
    }

    private static func record(
        _ action: ClaudeHooksAction,
        settingsURL: URL,
        in userDefaults: UserDefaults
    ) {
        var paths = Set(userDefaults.stringArray(forKey: managedSettingsPathsKey) ?? [])
        let path = settingsURL.standardizedFileURL.path
        switch action {
        case .install:
            paths.insert(path)
        case .remove:
            paths.remove(path)
        }
        userDefaults.set(paths.sorted(), forKey: managedSettingsPathsKey)
    }
}
