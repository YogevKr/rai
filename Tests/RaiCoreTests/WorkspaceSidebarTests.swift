import Foundation
import XCTest
@testable import RaiCore

final class WorkspaceSidebarTests: XCTestCase {
    func testParsesBranchAndAheadBehind() {
        let status = WorkspaceGit.parseStatus(
            """
            # branch.oid 8888
            # branch.head feature/sidebar
            # branch.upstream origin/feature/sidebar
            # branch.ab +3 -2
            """,
            checkoutPath: "/repo",
            repoKey: "/repo/.git"
        )

        XCTAssertEqual(status.branch, "feature/sidebar")
        XCTAssertFalse(status.isDetached)
        XCTAssertEqual(status.aheadBehind, GitAheadBehind(ahead: 3, behind: 2))
        XCTAssertEqual(status.repoKey, "/repo/.git")
    }

    func testParsesDetachedHeadWithoutInventingBranch() {
        let status = WorkspaceGit.parseStatus(
            """
            # branch.oid 8888
            # branch.head (detached)
            """,
            checkoutPath: "/repo",
            repoKey: "/repo/.git"
        )

        XCTAssertNil(status.branch)
        XCTAssertTrue(status.isDetached)
        XCTAssertNil(status.aheadBehind)
    }

    func testNonGitDirectoryHasNoStatus() throws {
        let directory = temporaryDirectory(named: "non-git")
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertNil(WorkspaceGit.status(at: directory.path))
    }

    func testLinkedWorktreeUsesPrimaryCommonGitDirectoryAsRepoKey() throws {
        let directory = temporaryDirectory(named: "repo-key")
        defer { try? FileManager.default.removeItem(at: directory) }
        let primaryGit = directory.appendingPathComponent("primary/.git")
        let linked = directory.appendingPathComponent("linked")
        let linkedGit = primaryGit.appendingPathComponent("worktrees/linked")
        try FileManager.default.createDirectory(
            at: linkedGit,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try "../../".write(
            to: linkedGit.appendingPathComponent("commondir"),
            atomically: true,
            encoding: .utf8
        )
        try "gitdir: \(linkedGit.path)\n".write(
            to: linked.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertEqual(
            WorkspaceGit.repositoryKey(at: linked.path),
            WorkspaceGit.normalizedCheckoutPath(primaryGit.path)
        )
    }

    func testCacheReadsEachCheckoutInSeriesOnlyWhenStale() async {
        let calls = LockedCalls()
        let cache = WorkspaceGitStatusCache(refreshInterval: 30) { path in
            calls.append(path)
            return WorkspaceGitStatus(
                checkoutPath: path,
                branch: "main",
                isDetached: false,
                aheadBehind: nil,
                repoKey: "\(path)/.git"
            )
        }
        let start = Date(timeIntervalSince1970: 100)

        _ = await cache.statuses(for: ["/repo-b", "/repo-a", "/repo-a"], now: start)
        _ = await cache.statuses(for: ["/repo-a", "/repo-b"], now: start.addingTimeInterval(29))
        XCTAssertEqual(calls.values, ["/repo-a", "/repo-b"])

        _ = await cache.statuses(for: ["/repo-a", "/repo-b"], now: start.addingTimeInterval(30))
        XCTAssertEqual(calls.values, ["/repo-a", "/repo-b", "/repo-a", "/repo-b"])
    }

    func testGroupsPrimaryAndLinkedWorktreesAtFirstMemberPosition() {
        let linked = workspace("w-linked", label: "rai-issue", path: "/rai-issue", linked: true)
        let primary = workspace("w-main", label: "rai", path: "/rai", linked: false)
        let notes = workspace("w-notes", label: "notes")
        let snapshot = snapshot(workspaces: [linked, primary, notes])
        let statuses = gitStatuses(
            (linked, "worktree/issue-12", "/rai/.git"),
            (primary, "main", "/rai/.git")
        )

        let entries = WorkspaceSidebar.entries(
            in: snapshot,
            gitStatuses: statuses,
            collapsedSpaceKeys: [],
            visibleWorkspaceID: nil
        )

        XCTAssertEqual(entries.map(\.workspace.workspaceID), ["w-main", "w-linked", "w-notes"])
        XCTAssertEqual(entries.map(\.displayLabel), ["rai", "issue-12", "notes"])
        XCTAssertEqual(entries.map(\.indented), [false, true, false])
        XCTAssertTrue(entries[0].isGroupParent)
        XCTAssertEqual(entries[0].groupKey, "/rai/.git")
    }

    func testDoesNotGroupOneMemberOrLinkedMembersWithoutPrimary() {
        let only = workspace("w-only", label: "only", path: "/only", linked: false)
        let linkedOne = workspace("w-one", label: "one", path: "/one", linked: true)
        let linkedTwo = workspace("w-two", label: "two", path: "/two", linked: true)
        let snapshot = snapshot(workspaces: [only, linkedOne, linkedTwo])
        let statuses = gitStatuses(
            (only, "main", "/only/.git"),
            (linkedOne, "one", "/shared/.git"),
            (linkedTwo, "two", "/shared/.git")
        )

        let entries = WorkspaceSidebar.entries(
            in: snapshot,
            gitStatuses: statuses,
            collapsedSpaceKeys: [],
            visibleWorkspaceID: nil
        )

        XCTAssertEqual(entries.map(\.workspace.workspaceID), ["w-only", "w-one", "w-two"])
        XCTAssertFalse(entries.contains(where: \.indented))
        XCTAssertFalse(entries.contains(where: \.isGroupParent))
    }

    func testCollapsedGroupHidesInactiveChildrenAndKeepsVisibleChild() {
        let primary = workspace("w-main", label: "rai", path: "/rai", linked: false)
        let issue = workspace(
            "w-issue",
            label: "rai-issue",
            path: "/issue",
            linked: true,
            status: .blocked
        )
        let review = workspace("w-review", label: "rai-review", path: "/review", linked: true)
        let snapshot = snapshot(workspaces: [primary, issue, review])
        let statuses = gitStatuses(
            (primary, "main", "/rai/.git"),
            (issue, "worktree/issue", "/rai/.git"),
            (review, "review", "/rai/.git")
        )

        let hidden = WorkspaceSidebar.entries(
            in: snapshot,
            gitStatuses: statuses,
            collapsedSpaceKeys: ["/rai/.git"],
            visibleWorkspaceID: nil
        )
        XCTAssertEqual(hidden.map(\.workspace.workspaceID), ["w-main"])
        XCTAssertEqual(hidden[0].displayStatus, .blocked)

        let visible = WorkspaceSidebar.entries(
            in: snapshot,
            gitStatuses: statuses,
            collapsedSpaceKeys: ["/rai/.git"],
            visibleWorkspaceID: "w-review"
        )
        XCTAssertEqual(visible.map(\.workspace.workspaceID), ["w-main", "w-review"])
        XCTAssertTrue(visible[1].indented)
        XCTAssertTrue(visible[1].groupCollapsed)
    }

    func testGroupedChildKeepsCustomWorkspaceLabel() {
        let primary = workspace("w-main", label: "rai", path: "/rai", linked: false)
        let issue = workspace(
            "w-issue",
            label: "Renamed issue",
            path: "/rai-issue",
            linked: true
        )
        let snapshot = snapshot(workspaces: [primary, issue])
        let statuses = gitStatuses(
            (primary, "main", "/rai/.git"),
            (issue, "worktree/issue", "/rai/.git")
        )

        let entries = WorkspaceSidebar.entries(
            in: snapshot,
            gitStatuses: statuses,
            collapsedSpaceKeys: [],
            visibleWorkspaceID: nil
        )

        XCTAssertEqual(entries[1].displayLabel, "Renamed issue")
    }

    func testCheckoutPathPrefersWorktreeThenActivePaneForegroundDirectory() {
        let worktree = workspace("w-tree", label: "tree", path: "/tree", linked: false)
        let plain = workspace("w-plain", label: "plain", activeTabID: "t-active")
        let snapshot = snapshot(
            workspaces: [worktree, plain],
            panes: [
                pane("p-other", workspaceID: "w-plain", tabID: "t-other", cwd: "/other"),
                pane(
                    "p-active",
                    workspaceID: "w-plain",
                    tabID: "t-active",
                    cwd: "/shell",
                    foregroundCWD: "/foreground"
                ),
            ]
        )

        XCTAssertEqual(
            WorkspaceSidebar.checkoutPath(for: worktree, in: snapshot),
            "/tree"
        )
        XCTAssertEqual(
            WorkspaceSidebar.checkoutPath(for: plain, in: snapshot),
            "/foreground"
        )
    }

    func testTabCheckoutPathPrefersFocusedPaneShellDirectory() {
        let space = workspace("w-plain", label: "plain", activeTabID: "t-a")
        let tabs = [
            tab("t-a", workspaceID: "w-plain"),
            tab("t-b", workspaceID: "w-plain"),
            tab("t-empty", workspaceID: "w-plain"),
        ]
        let snapshot = snapshot(
            workspaces: [space],
            tabs: tabs,
            panes: [
                pane("p-first", workspaceID: "w-plain", tabID: "t-a", cwd: "/repo"),
                pane(
                    "p-focused",
                    workspaceID: "w-plain",
                    tabID: "t-a",
                    cwd: "/repo/.worktrees/x",
                    foregroundCWD: "/helper",
                    focused: true
                ),
                pane(
                    "p-no-shell-cwd",
                    workspaceID: "w-plain",
                    tabID: "t-b",
                    cwd: "",
                    foregroundCWD: "/foreground"
                ),
            ]
        )

        // The focused pane's shell directory wins over the first pane and
        // over the foreground process directory (an MCP helper elsewhere).
        XCTAssertEqual(
            WorkspaceSidebar.checkoutPath(for: tabs[0], in: snapshot),
            "/repo/.worktrees/x"
        )
        XCTAssertEqual(
            WorkspaceSidebar.checkoutPath(for: tabs[1], in: snapshot),
            "/foreground"
        )
        XCTAssertNil(WorkspaceSidebar.checkoutPath(for: tabs[2], in: snapshot))
    }

    func testCheckoutPathsCoverSpacesAndTabsOnce() {
        let tree = workspace("w-tree", label: "tree", path: "/tree", linked: false)
        let snapshot = snapshot(
            workspaces: [tree],
            tabs: [
                tab("t-root", workspaceID: "w-tree"),
                tab("t-worktree", workspaceID: "w-tree"),
            ],
            panes: [
                pane("p-root", workspaceID: "w-tree", tabID: "t-root", cwd: "/tree"),
                pane(
                    "p-worktree",
                    workspaceID: "w-tree",
                    tabID: "t-worktree",
                    cwd: "/tree/.worktrees/x"
                ),
            ]
        )

        XCTAssertEqual(
            WorkspaceSidebar.checkoutPaths(in: snapshot),
            ["/tree", "/tree/.worktrees/x"]
        )
    }

    func testTabGitStatusReadsItsOwnDirectoryNotTheSpace() {
        let tree = workspace("w-tree", label: "tree", path: "/tree", linked: false)
        let rootTab = tab("t-root", workspaceID: "w-tree")
        let worktreeTab = tab("t-worktree", workspaceID: "w-tree")
        let snapshot = snapshot(
            workspaces: [tree],
            tabs: [rootTab, worktreeTab],
            panes: [
                pane("p-root", workspaceID: "w-tree", tabID: "t-root", cwd: "/tree"),
                pane(
                    "p-worktree",
                    workspaceID: "w-tree",
                    tabID: "t-worktree",
                    cwd: "/tree/.worktrees/x"
                ),
            ]
        )
        let statuses = [
            "/tree": WorkspaceGitStatus(
                checkoutPath: "/tree", branch: "main", isDetached: false,
                aheadBehind: nil, repoKey: "repo"
            ),
            "/tree/.worktrees/x": WorkspaceGitStatus(
                checkoutPath: "/tree/.worktrees/x", branch: "feature", isDetached: false,
                aheadBehind: GitAheadBehind(ahead: 1, behind: 0), repoKey: "repo"
            ),
        ]

        XCTAssertEqual(
            WorkspaceSidebar.gitStatus(for: rootTab, in: snapshot, gitStatuses: statuses)?.branch,
            "main"
        )
        XCTAssertEqual(
            WorkspaceSidebar.gitStatus(for: worktreeTab, in: snapshot, gitStatuses: statuses)?.branch,
            "feature"
        )
        XCTAssertEqual(
            WorkspaceSidebar.gitStatus(for: tree, in: snapshot, gitStatuses: statuses)?.branch,
            "main"
        )
    }

    private func tab(_ id: String, workspaceID: String) -> HerdrTab {
        HerdrTab(
            tabID: id,
            workspaceID: workspaceID,
            number: 1,
            label: id,
            focused: false,
            paneCount: 1,
            agentStatus: .idle
        )
    }

    private func workspace(
        _ id: String,
        label: String,
        activeTabID: String = "",
        path: String? = nil,
        linked: Bool = false,
        status: AgentStatus = .idle
    ) -> Workspace {
        Workspace(
            workspaceID: id,
            number: 1,
            label: label,
            focused: false,
            paneCount: 1,
            tabCount: 1,
            activeTabID: activeTabID,
            agentStatus: status,
            worktree: path.map {
                WorkspaceWorktree(
                    repoKey: nil,
                    repoName: "rai",
                    repoRoot: nil,
                    checkoutPath: $0,
                    isLinkedWorktree: linked
                )
            }
        )
    }

    private func pane(
        _ id: String,
        workspaceID: String,
        tabID: String,
        cwd: String,
        foregroundCWD: String? = nil,
        focused: Bool = false
    ) -> Pane {
        Pane(
            paneID: id,
            terminalID: "term-\(id)",
            workspaceID: workspaceID,
            tabID: tabID,
            focused: focused,
            cwd: cwd,
            foregroundCWD: foregroundCWD,
            agent: nil,
            agentSession: nil,
            terminalTitle: nil,
            terminalTitleStripped: nil,
            agentStatus: .idle,
            revision: 1,
            scroll: nil
        )
    }

    private func snapshot(
        workspaces: [Workspace],
        tabs: [HerdrTab] = [],
        panes: [Pane] = []
    ) -> SessionSnapshot {
        SessionSnapshot(
            version: "0.7.4",
            protocol: 16,
            focusedWorkspaceID: nil,
            focusedTabID: nil,
            focusedPaneID: nil,
            workspaces: workspaces,
            tabs: tabs,
            panes: panes,
            agents: nil,
            layouts: []
        )
    }

    private func gitStatuses(
        _ values: (Workspace, String, String)...
    ) -> [String: WorkspaceGitStatus] {
        Dictionary(uniqueKeysWithValues: values.compactMap { workspace, branch, repoKey in
            guard let path = workspace.worktree?.checkoutPath else { return nil }
            let normalized = WorkspaceGit.normalizedCheckoutPath(path)
            return (
                normalized,
                WorkspaceGitStatus(
                    checkoutPath: normalized,
                    branch: branch,
                    isDetached: false,
                    aheadBehind: nil,
                    repoKey: repoKey
                )
            )
        })
    }

    private func temporaryDirectory(named name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("rai-\(name)-\(UUID().uuidString)")
    }
}

private final class LockedCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }
}
