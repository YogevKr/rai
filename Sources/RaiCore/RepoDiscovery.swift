import Foundation

/// A git checkout found under a configured project root. The palette offers it
/// as a space you can open, next to the spaces that are already open.
public struct DiscoveredRepo: Identifiable, Sendable, Equatable, Hashable {
    public let path: String
    public let name: String

    public var id: String { path }

    public init(path: String, name: String) {
        self.path = path
        self.name = name
    }
}

/// Pure planning for repo discovery: the roots to scan, the remote scan script,
/// how to read its output, and the herdr command that turns a repo into a space.
///
/// Discovery deliberately runs on the *herd's* host, not on the Mac. When rai is
/// attached to a remote herd, a local file picker would browse the wrong
/// machine; scanning where the daemon lives makes every path correct by
/// construction.
public enum RepoDiscoveryPlanner {
    /// Roots scanned when the user has not configured their own.
    public static let defaultRoots = ["~/repos", "~/projects"]

    /// How many directory levels below a root a checkout may sit. `1` means the
    /// repos are the root's immediate children, which is the common layout.
    public static let defaultDepth = 1

    public static let maxDepth = 4

    // MARK: - Opening a repo

    /// `workspace create` for a repo. herdr also creates the first tab and root
    /// pane, both already inside the checkout, so one call is the whole flow.
    public static func workspaceCreateArguments(path: String, label: String) -> [String] {
        var arguments = ["workspace", "create", "--cwd", path]
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            arguments += ["--label", trimmed]
        }
        arguments.append("--focus")
        return arguments
    }

    /// The space label for a checkout: its directory name.
    public static func name(for path: String) -> String {
        let component = (normalized(path) as NSString).lastPathComponent
        return component.isEmpty ? path : component
    }

    // MARK: - Scanning

    /// Shell script that prints one `.git` path per line for every checkout
    /// under `roots`. Used for remote herds, where the scan runs over ssh.
    ///
    /// `-name .git` matches both a clone's `.git` directory and a linked
    /// worktree's `.git` file, so worktrees are found too. `-prune` stops find
    /// from walking into the object store.
    public static func scanScript(roots: [String], depth: Int) -> String {
        let clamped = min(max(depth, 1), maxDepth)
        let quoted = roots
            .map(shellArgument)
            .filter { !$0.isEmpty }
        guard !quoted.isEmpty else { return "" }
        // A checkout `depth` levels below the root puts its `.git` one deeper.
        return "for d in \(quoted.joined(separator: " ")); do "
            + "find \"$d\" -mindepth 2 -maxdepth \(clamped + 1) "
            + "-name .git -prune -print 2>/dev/null; "
            + "done"
    }

    /// Reads `scanScript` output into repos, dropping the trailing `/.git`.
    public static func parse(scanOutput: String) -> [DiscoveredRepo] {
        var seen = Set<String>()
        var repos: [DiscoveredRepo] = []
        for line in scanOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            let marker = line.trimmingCharacters(in: .whitespaces)
            guard marker.hasSuffix("/.git") else { continue }
            let path = String(marker.dropLast("/.git".count))
            guard !path.isEmpty, seen.insert(normalized(path)).inserted else { continue }
            repos.append(DiscoveredRepo(path: path, name: name(for: path)))
        }
        return sorted(repos)
    }

    // MARK: - Filtering

    /// Repos worth offering. A repo whose checkout already backs an open space
    /// is dropped: that space is its own palette row, so offering "open" beside
    /// it would be a duplicate that creates a second space for one directory.
    public static func candidates(
        repos: [DiscoveredRepo],
        openPaths: [String]
    ) -> [DiscoveredRepo] {
        let open = Set(openPaths.map(normalized))
        return sorted(repos.filter { !open.contains(normalized($0.path)) })
    }

    /// A query that names a directory outright — absolute or ~-rooted — as the
    /// expanded path. Anything else is a fuzzy search, not a path.
    public static func explicitPathQuery(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/") || trimmed == "~" || trimmed.hasPrefix("~/") else {
            return nil
        }
        let expanded = normalized(trimmed)
        guard expanded.hasPrefix("/") else { return nil }
        return expanded
    }

    // MARK: - Helpers

    /// Trailing slashes and `.`/`..` segments would defeat set-based dedupe, so
    /// every comparison goes through one spelling of a path.
    public static func normalized(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
        guard standardized.count > 1, standardized.hasSuffix("/") else { return standardized }
        return String(standardized.dropLast())
    }

    /// Shortens a path for display, so `/Users/me/repos/rai` reads as `~/repos/rai`.
    public static func displayPath(_ path: String) -> String {
        NSString(string: path).abbreviatingWithTildeInPath
    }

    private static func sorted(_ repos: [DiscoveredRepo]) -> [DiscoveredRepo] {
        repos.sorted {
            let byName = $0.name.localizedCaseInsensitiveCompare($1.name)
            return byName == .orderedSame ? $0.path < $1.path : byName == .orderedAscending
        }
    }

    /// Quotes one root for the remote scan. A leading `~` becomes `$HOME` so the
    /// remote shell expands it against the *remote* user, not this Mac.
    static func shellArgument(_ root: String) -> String {
        let trimmed = root.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        if trimmed == "~" { return "\"$HOME\"" }
        if trimmed.hasPrefix("~/") {
            let rest = String(trimmed.dropFirst(2))
            return rest.isEmpty ? "\"$HOME\"" : "\"$HOME\"/" + singleQuoted(rest)
        }
        return singleQuoted(trimmed)
    }

    private static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
