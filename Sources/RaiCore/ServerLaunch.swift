import Foundation

/// How rai starts a herdr server for a herd that is not running.
public enum HerdrServerLaunch {
    /// Arguments that run a headless server for `session`.
    ///
    /// The default session takes no `--session` flag: `herdr --session default
    /// server` would create a *separate* named herd under `sessions/default`
    /// instead of the default one at `~/.config/herdr/herdr.sock`.
    public static func serverArguments(for session: HerdrSession) -> [String] {
        session.isDefault ? ["server"] : ["--session", session.name, "server"]
    }

    /// The herd rai should start for itself on open, or nil when it must not.
    ///
    /// Returns nil for a socket herdr does not know (a custom
    /// `HERDR_SOCKET_PATH`, or a remote herd behind an SSH tunnel): rai cannot
    /// tell how to start that server, so it stays out of the way.
    public static func autostartTarget(
        socketPath: String,
        sessions: [HerdrSession]
    ) -> HerdrSession? {
        guard let session = sessions.first(where: {
            pathsMatch($0.socketPath, socketPath)
        }) else {
            return nil
        }
        return session.isRunning ? nil : session
    }

    private static func pathsMatch(_ lhs: String, _ rhs: String) -> Bool {
        normalized(lhs) == normalized(rhs)
    }

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            .standardizedFileURL.path
    }
}
