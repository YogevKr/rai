import Foundation

/// App-owned storage. Test launches supply a private root without changing HOME.
public struct AppDataPaths: Sendable {
    public static let current = AppDataPaths(environment: ProcessInfo.processInfo.environment)

    public let isolatedRoot: URL?
    private let home: URL
    private let support: URL
    public let herdrConfigFile: URL
    public let herdrDirectory: URL

    public init(
        environment: [String: String],
        home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        support: URL? = nil
    ) {
        self.home = home
        let configRoot = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".config", isDirectory: true)
        herdrDirectory = configRoot.appendingPathComponent("herdr", isDirectory: true)
        herdrConfigFile = environment["HERDR_CONFIG_PATH"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? herdrDirectory.appendingPathComponent("config.toml")
        self.support = support ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        if let path = environment["RAI_DATA_ROOT"] {
            precondition(path.hasPrefix("/") && path != "/", "RAI_DATA_ROOT must name an absolute test directory")
            isolatedRoot = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        } else {
            isolatedRoot = nil
        }
    }

    public var isIsolated: Bool { isolatedRoot != nil }

    public var applicationSupport: URL {
        isolatedRoot?.appendingPathComponent("support", isDirectory: true)
            ?? support.appendingPathComponent("Rai", isDirectory: true)
    }

    public var claudeDirectory: URL {
        isolatedRoot?.appendingPathComponent("claude", isDirectory: true)
            ?? home.appendingPathComponent(".claude", isDirectory: true)
    }

    /// Other Herdr integrations still resolve account-owned paths without overrides.
    public func canManageIntegration(_ name: String) -> Bool {
        !isIsolated || ["claude", "codex"].contains(name)
    }
}
