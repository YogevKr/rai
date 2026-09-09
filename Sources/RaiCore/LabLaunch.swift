import Foundation

public enum LabLaunch {
    public struct InvalidConfiguration: LocalizedError {
        public let errorDescription: String?
    }

    /// A lab bundle must never fall back to the user's normal stores or server.
    public static func validate(bundleIdentifier: String, environment: [String: String]) throws {
        guard bundleIdentifier.hasPrefix("gr.krig.rai.lab.") else { return }
        guard let rootPath = environment["RAI_DATA_ROOT"], rootPath.hasPrefix("/"), rootPath != "/" else {
            throw InvalidConfiguration(errorDescription: "Lab launch requires RAI_DATA_ROOT.")
        }
        guard let root = resolvedPath(rootPath), root.path != "/" else {
            throw InvalidConfiguration(errorDescription: "Lab directory could not be resolved.")
        }
        let marker = root.appendingPathComponent(".rai-lab-owned")
        guard (try? String(contentsOf: marker, encoding: .utf8)) == bundleIdentifier else {
            throw InvalidConfiguration(errorDescription: "Lab ownership marker does not match this bundle.")
        }
        for key in ["HERDR_SOCKET_PATH", "HERDR_CONFIG_PATH", "HERDR_BIN_PATH", "RAI_HOOK_SOCKET_PATH",
                    "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "RAI_PAIRING_CODE_FILE",
                    "TMPDIR", "CLAUDE_CONFIG_DIR", "CODEX_HOME", "ZDOTDIR", "GIT_CONFIG_GLOBAL"] {
            guard let path = environment[key], let resolved = resolvedPath(path),
                  resolved.path.hasPrefix(root.path + "/") else {
                throw InvalidConfiguration(errorDescription: "\(key) must stay inside the lab directory.")
            }
        }
        guard let binary = environment["HERDR_BIN_PATH"],
              ExecutableFile.isAvailable(at: binary)
                || (environment["RAI_LAB_ALLOW_MISSING_HERDR"] == "1"
                    && !FileManager.default.fileExists(atPath: binary)) else {
            throw InvalidConfiguration(errorDescription: "Lab Herdr executable is unavailable.")
        }
        guard let rawPort = environment["RAI_BRIDGE_PORT"], let port = UInt16(rawPort),
              port > 1024, port != 47837 else {
            throw InvalidConfiguration(errorDescription: "Lab launch requires a separate bridge port.")
        }
    }

    public static func requireContainedPath(_ path: String, root: URL?) throws {
        guard let root else { return }
        guard let resolvedRoot = resolvedPath(root.path), let resolved = resolvedPath(path),
              resolved.path.hasPrefix(resolvedRoot.path + "/") else {
            throw InvalidConfiguration(errorDescription: "This action must stay inside the lab directory.")
        }
    }

    public static func requireRemoteAccess(isIsolated: Bool) throws {
        guard !isIsolated else {
            throw InvalidConfiguration(errorDescription: "Remote lab actions require a disposable SSH account and configuration.")
        }
    }

    public static func recordServer(pid: Int32, executable: String, socketPath: String, root: URL?) throws {
        guard let root else { return }
        try requireContainedPath(executable, root: root)
        try requireContainedPath(socketPath, root: root)
        let record = root.appendingPathComponent("herdr-\(pid).json")
        try requireContainedPath(record.path, root: root)
        let data = try JSONSerialization.data(withJSONObject: [
            "pid": pid, "executable": executable, "socket": socketPath, "root": root.path,
        ], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: record, options: .atomic)
    }

    /// Foundation can leave symlinks unresolved when the final socket does not exist yet.
    private static func resolvedPath(_ path: String) -> URL? {
        guard path.hasPrefix("/"), !(path as NSString).pathComponents.contains("..") else { return nil }
        let manager = FileManager.default
        var existing = URL(fileURLWithPath: path)
        var suffix: [String] = []
        while !manager.fileExists(atPath: existing.path) {
            guard existing.path != "/",
                  (try? manager.destinationOfSymbolicLink(atPath: existing.path)) == nil else { return nil }
            suffix.append(existing.lastPathComponent)
            existing.deleteLastPathComponent()
        }
        return suffix.reversed().reduce(existing.resolvingSymlinksInPath().standardizedFileURL) {
            $0.appendingPathComponent($1)
        }
    }
}
