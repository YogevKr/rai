import Foundation

public struct GitAheadBehind: Sendable, Equatable {
    public let ahead: Int
    public let behind: Int

    public init(ahead: Int, behind: Int) {
        self.ahead = ahead
        self.behind = behind
    }
}

public struct WorkspaceGitStatus: Sendable, Equatable {
    public let checkoutPath: String
    public let branch: String?
    public let isDetached: Bool
    public let aheadBehind: GitAheadBehind?
    public let repoKey: String?

    public init(
        checkoutPath: String,
        branch: String?,
        isDetached: Bool,
        aheadBehind: GitAheadBehind?,
        repoKey: String?
    ) {
        self.checkoutPath = checkoutPath
        self.branch = branch
        self.isDetached = isDetached
        self.aheadBehind = aheadBehind
        self.repoKey = repoKey
    }
}

public enum WorkspaceGit {
    public static func status(at checkoutPath: String) -> WorkspaceGitStatus? {
#if os(macOS)
        let path = normalizedCheckoutPath(checkoutPath)
        let process = Process()
        let output = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-C", path,
            "status", "--porcelain=v2", "--branch", "--untracked-files=no",
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["LC_ALL"] = "C"
        process.environment = environment

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return parseStatus(
            text,
            checkoutPath: path,
            repoKey: repositoryKey(at: path)
        )
#else
        nil
#endif
    }

    public static func parseStatus(
        _ output: String,
        checkoutPath: String,
        repoKey: String?
    ) -> WorkspaceGitStatus {
        var branch: String?
        var detached = false
        var aheadBehind: GitAheadBehind?

        for line in output.split(separator: "\n") {
            if line.hasPrefix("# branch.head ") {
                let value = line.dropFirst("# branch.head ".count)
                if value == "(detached)" {
                    detached = true
                } else if value != "(unknown)" {
                    branch = String(value)
                }
            } else if line.hasPrefix("# branch.ab ") {
                let counts = line.dropFirst("# branch.ab ".count).split(separator: " ")
                guard counts.count == 2,
                      let ahead = Int(counts[0].dropFirst()),
                      let behind = Int(counts[1].dropFirst()) else {
                    continue
                }
                aheadBehind = GitAheadBehind(ahead: ahead, behind: behind)
            }
        }

        return WorkspaceGitStatus(
            checkoutPath: normalizedCheckoutPath(checkoutPath),
            branch: branch,
            isDetached: detached,
            aheadBehind: aheadBehind,
            repoKey: repoKey
        )
    }

    public static func normalizedCheckoutPath(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    /// The common Git directory is stable across a primary checkout and its
    /// linked worktrees. Reading its marker avoids another Git process per row.
    public static func repositoryKey(at checkoutPath: String) -> String? {
        var directory = URL(
            fileURLWithPath: normalizedCheckoutPath(checkoutPath),
            isDirectory: true
        )
        let fileManager = FileManager.default

        while true {
            let marker = directory.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: marker.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    return normalizedCheckoutPath(marker.path)
                }
                guard let contents = try? String(contentsOf: marker, encoding: .utf8),
                      let gitDirectory = resolveGitDirectory(
                          contents: contents,
                          relativeTo: directory
                      ) else {
                    return nil
                }
                let commonDirectory = resolveCommonDirectory(in: gitDirectory)
                    ?? gitDirectory
                return normalizedCheckoutPath(commonDirectory.path)
            }

            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path {
                return nil
            }
            directory = parent
        }
    }

    private static func resolveGitDirectory(
        contents: String,
        relativeTo checkout: URL
    ) -> URL? {
        guard let path = contents
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .dropPrefix("gitdir:")
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces),
            !path.isEmpty else {
            return nil
        }
        if NSString(string: path).isAbsolutePath {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        return checkout.appendingPathComponent(path, isDirectory: true).standardizedFileURL
    }

    private static func resolveCommonDirectory(in gitDirectory: URL) -> URL? {
        let marker = gitDirectory.appendingPathComponent("commondir")
        guard let path = try? String(contentsOf: marker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty else {
            return nil
        }
        if NSString(string: path).isAbsolutePath {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        return gitDirectory.appendingPathComponent(path, isDirectory: true).standardizedFileURL
    }
}

public actor WorkspaceGitStatusCache {
    public typealias Reader = @Sendable (String) -> WorkspaceGitStatus?

    private struct Entry {
        let status: WorkspaceGitStatus?
        let refreshedAt: Date
    }

    private let refreshInterval: TimeInterval
    private let reader: Reader
    private var entries: [String: Entry] = [:]

    public init(refreshInterval: TimeInterval = 30) {
        self.refreshInterval = refreshInterval
        reader = { WorkspaceGit.status(at: $0) }
    }

    public init(refreshInterval: TimeInterval, reader: @escaping Reader) {
        self.refreshInterval = refreshInterval
        self.reader = reader
    }

    /// Reads stale paths in series. A snapshot with many spaces cannot launch
    /// all Git processes at once.
    public func statuses(
        for checkoutPaths: [String],
        now: Date = Date()
    ) -> [String: WorkspaceGitStatus] {
        let paths = Array(
            Set(checkoutPaths.map(WorkspaceGit.normalizedCheckoutPath))
        ).sorted()
        entries = entries.filter { paths.contains($0.key) }

        for path in paths {
            if let entry = entries[path],
               now.timeIntervalSince(entry.refreshedAt) < refreshInterval {
                continue
            }
            guard !Task.isCancelled else { break }
            entries[path] = Entry(status: reader(path), refreshedAt: now)
        }

        return paths.reduce(into: [:]) { result, path in
            if let status = entries[path]?.status {
                result[path] = status
            }
        }
    }
}

public struct WorkspaceListEntry: Identifiable, Sendable, Equatable {
    public let workspace: Workspace
    public let displayLabel: String
    public let indented: Bool
    public let groupKey: String?
    public let groupCollapsed: Bool
    public let displayStatus: AgentStatus

    public var id: String { workspace.workspaceID }
    public var isGroupParent: Bool { groupKey != nil && !indented }
}

public enum WorkspaceSidebar {
    public static func checkoutPaths(in snapshot: SessionSnapshot) -> [String] {
        snapshot.workspaces.compactMap {
            checkoutPath(for: $0, in: snapshot)
        }
    }

    public static func checkoutPath(
        for workspace: Workspace,
        in snapshot: SessionSnapshot
    ) -> String? {
        if let path = workspace.worktree?.checkoutPath, !path.isEmpty {
            return WorkspaceGit.normalizedCheckoutPath(path)
        }

        let panes = snapshot.panes.filter { $0.workspaceID == workspace.workspaceID }
        let activeTabPanes = panes.filter { $0.tabID == workspace.activeTabID }
        let pane = activeTabPanes.first(where: \.focused)
            ?? activeTabPanes.first
            ?? panes.first(where: \.focused)
            ?? panes.first
        let path = pane?.foregroundCWD ?? pane?.cwd
        guard let path, !path.isEmpty else { return nil }
        return WorkspaceGit.normalizedCheckoutPath(path)
    }

    public static func entries(
        in snapshot: SessionSnapshot,
        gitStatuses: [String: WorkspaceGitStatus],
        collapsedSpaceKeys: Set<String>,
        visibleWorkspaceID: String?
    ) -> [WorkspaceListEntry] {
        let membersByKey = Dictionary(grouping: snapshot.workspaces.indices) { index in
            repositoryKey(
                for: snapshot.workspaces[index],
                in: snapshot,
                gitStatuses: gitStatuses
            )
        }
        // Herdr needs one primary member, but it does not require a linked one.
        // Two spaces at the primary checkout still form one repo group.
        let groupedKeys = Set(membersByKey.compactMap { key, members -> String? in
            guard let key,
                  members.count >= 2,
                  members.contains(where: {
                      snapshot.workspaces[$0].worktree?.isLinkedWorktree == false
                  }) else {
                return nil
            }
            return key
        })
        let visibleGroupKey = visibleWorkspaceID
            .flatMap { id in snapshot.workspaces.first { $0.workspaceID == id } }
            .flatMap {
                repositoryKey(for: $0, in: snapshot, gitStatuses: gitStatuses)
            }

        var emittedKeys = Set<String>()
        var result: [WorkspaceListEntry] = []

        for workspace in snapshot.workspaces {
            guard let key = repositoryKey(
                for: workspace,
                in: snapshot,
                gitStatuses: gitStatuses
            ), groupedKeys.contains(key) else {
                result.append(entry(for: workspace, in: snapshot, gitStatuses: gitStatuses))
                continue
            }
            guard emittedKeys.insert(key).inserted,
                  let members = membersByKey[key],
                  let parentIndex = members.first(where: {
                      snapshot.workspaces[$0].worktree?.isLinkedWorktree == false
                  }) else {
                continue
            }

            let collapsed = collapsedSpaceKeys.contains(key)
            let parent = snapshot.workspaces[parentIndex]
            result.append(
                entry(
                    for: parent,
                    in: snapshot,
                    gitStatuses: gitStatuses,
                    groupKey: key,
                    groupCollapsed: collapsed,
                    displayStatus: collapsed
                        ? aggregateStatus(for: members, in: snapshot)
                        : parent.agentStatus
                )
            )

            if collapsed {
                // Herdr keeps only the active child in a collapsed group. The
                // parent carries all hidden attention through its aggregate state.
                if visibleGroupKey == key,
                   let visibleWorkspaceID,
                   visibleWorkspaceID != parent.workspaceID,
                   let child = snapshot.workspaces.first(where: {
                       $0.workspaceID == visibleWorkspaceID
                   }) {
                    result.append(
                        entry(
                            for: child,
                            in: snapshot,
                            gitStatuses: gitStatuses,
                            indented: true,
                            groupKey: key,
                            groupCollapsed: true
                        )
                    )
                }
                continue
            }

            for memberIndex in members where memberIndex != parentIndex {
                result.append(
                    entry(
                        for: snapshot.workspaces[memberIndex],
                        in: snapshot,
                        gitStatuses: gitStatuses,
                        indented: true,
                        groupKey: key
                    )
                )
            }
        }
        return result
    }

    public static func gitStatus(
        for workspace: Workspace,
        in snapshot: SessionSnapshot,
        gitStatuses: [String: WorkspaceGitStatus]
    ) -> WorkspaceGitStatus? {
        guard let path = checkoutPath(for: workspace, in: snapshot) else { return nil }
        return gitStatuses[path]
    }

    /// Change this accessor to `worktree.repoKey` when that wire field lands.
    private static func repositoryKey(
        for workspace: Workspace,
        in snapshot: SessionSnapshot,
        gitStatuses: [String: WorkspaceGitStatus]
    ) -> String? {
        guard workspace.worktree != nil else { return nil }
        return gitStatus(for: workspace, in: snapshot, gitStatuses: gitStatuses)?.repoKey
    }

    private static func entry(
        for workspace: Workspace,
        in snapshot: SessionSnapshot,
        gitStatuses: [String: WorkspaceGitStatus],
        indented: Bool = false,
        groupKey: String? = nil,
        groupCollapsed: Bool = false,
        displayStatus: AgentStatus? = nil
    ) -> WorkspaceListEntry {
        let status = gitStatus(for: workspace, in: snapshot, gitStatuses: gitStatuses)
        let checkoutName = workspace.worktree.map {
            URL(fileURLWithPath: $0.checkoutPath).lastPathComponent
        }
        // The snapshot omits Herdr's custom-name flag. Its automatic worktree
        // label is the checkout directory name, which is the available signal.
        let hasCustomLabel = checkoutName.map { $0 != workspace.label } ?? false
        let label = indented && !hasCustomLabel
            ? groupedChildDisplayLabel(workspace.label, branch: status?.branch)
            : workspace.label
        return WorkspaceListEntry(
            workspace: workspace,
            displayLabel: label,
            indented: indented,
            groupKey: groupKey,
            groupCollapsed: groupCollapsed,
            displayStatus: displayStatus ?? workspace.agentStatus
        )
    }

    private static func aggregateStatus(
        for memberIndices: [Int],
        in snapshot: SessionSnapshot
    ) -> AgentStatus {
        memberIndices
            .map { snapshot.workspaces[$0].agentStatus }
            .max { attentionPriority($0) < attentionPriority($1) }
            ?? .unknown
    }

    private static func attentionPriority(_ status: AgentStatus) -> Int {
        switch status {
        case .blocked: 4
        case .done: 3
        case .working: 2
        case .idle: 1
        case .unknown: 0
        }
    }

    private static func groupedChildDisplayLabel(
        _ fallback: String,
        branch: String?
    ) -> String {
        guard let branch else { return fallback }
        return branch.dropPrefix("worktree/").map(String.init) ?? branch
    }
}

private extension Substring {
    func dropPrefix(_ prefix: String) -> Substring? {
        hasPrefix(prefix) ? dropFirst(prefix.count) : nil
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> Substring? {
        self[...].dropPrefix(prefix)
    }
}
