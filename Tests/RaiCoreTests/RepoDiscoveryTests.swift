import XCTest
@testable import RaiCore

final class RepoDiscoveryTests: XCTestCase {
    // MARK: - Opening a repo

    func testWorkspaceCreateCarriesCwdAndLabel() {
        XCTAssertEqual(
            RepoDiscoveryPlanner.workspaceCreateArguments(path: "/Users/x/repos/rai", label: "rai"),
            ["workspace", "create", "--cwd", "/Users/x/repos/rai", "--label", "rai", "--focus"]
        )
    }

    func testWorkspaceCreateDropsAnEmptyLabel() {
        XCTAssertEqual(
            RepoDiscoveryPlanner.workspaceCreateArguments(path: "/tmp/a", label: "   "),
            ["workspace", "create", "--cwd", "/tmp/a", "--focus"]
        )
    }

    func testNameIsTheDirectoryName() {
        XCTAssertEqual(RepoDiscoveryPlanner.name(for: "/Users/x/repos/rai"), "rai")
        XCTAssertEqual(RepoDiscoveryPlanner.name(for: "/Users/x/repos/rai/"), "rai")
    }

    // MARK: - Scan script

    func testScanScriptExpandsTildeOnTheRemoteHost() {
        let script = RepoDiscoveryPlanner.scanScript(roots: ["~/repos"], depth: 1)
        // `$HOME` must survive into the remote shell; expanding it here would
        // send this Mac's home directory to the other machine.
        XCTAssertTrue(script.contains("\"$HOME\"/'repos'"), script)
        XCTAssertFalse(script.contains(NSHomeDirectory()), script)
    }

    func testScanScriptQuotesPathsWithSpacesAndQuotes() {
        let script = RepoDiscoveryPlanner.scanScript(roots: ["/tmp/my code", "/tmp/it's"], depth: 1)
        XCTAssertTrue(script.contains("'/tmp/my code'"), script)
        XCTAssertTrue(script.contains("'/tmp/it'\\''s'"), script)
    }

    func testScanScriptDepthBecomesMaxdepthOneDeeper() {
        // A checkout `depth` levels down puts its `.git` marker one level below.
        XCTAssertTrue(
            RepoDiscoveryPlanner.scanScript(roots: ["/tmp"], depth: 1).contains("-maxdepth 2")
        )
        XCTAssertTrue(
            RepoDiscoveryPlanner.scanScript(roots: ["/tmp"], depth: 3).contains("-maxdepth 4")
        )
    }

    func testScanScriptClampsDepthAndHandlesNoRoots() {
        XCTAssertTrue(
            RepoDiscoveryPlanner.scanScript(roots: ["/tmp"], depth: 99)
                .contains("-maxdepth \(RepoDiscoveryPlanner.maxDepth + 1)")
        )
        XCTAssertTrue(
            RepoDiscoveryPlanner.scanScript(roots: ["/tmp"], depth: 0).contains("-maxdepth 2")
        )
        XCTAssertEqual(RepoDiscoveryPlanner.scanScript(roots: [], depth: 1), "")
        XCTAssertEqual(RepoDiscoveryPlanner.scanScript(roots: ["  "], depth: 1), "")
    }

    // MARK: - Parsing

    func testParseStripsTheGitMarkerAndSorts() {
        let repos = RepoDiscoveryPlanner.parse(
            scanOutput: """
            /home/y/repos/zebra/.git
            /home/y/repos/alpha/.git
            """
        )
        XCTAssertEqual(repos.map(\.name), ["alpha", "zebra"])
        XCTAssertEqual(repos.map(\.path), ["/home/y/repos/alpha", "/home/y/repos/zebra"])
    }

    func testParseIgnoresNoiseAndDuplicates() {
        let repos = RepoDiscoveryPlanner.parse(
            scanOutput: """
            find: /home/y/private: Permission denied
            /home/y/repos/rai/.git

            /home/y/repos/rai/.git
            /home/y/repos/notarepo
            """
        )
        XCTAssertEqual(repos.map(\.path), ["/home/y/repos/rai"])
    }

    // MARK: - Filtering

    func testCandidatesDropReposAnOpenSpaceAlreadySitsIn() {
        let repos = [
            DiscoveredRepo(path: "/home/y/repos/rai", name: "rai"),
            DiscoveredRepo(path: "/home/y/repos/herdr", name: "herdr"),
        ]
        let candidates = RepoDiscoveryPlanner.candidates(
            repos: repos,
            // A pane's cwd arrives with a trailing slash often enough that the
            // comparison has to normalize, or the repo is offered twice.
            openPaths: ["/home/y/repos/rai/"]
        )
        XCTAssertEqual(candidates.map(\.name), ["herdr"])
    }

    func testCandidatesMatchTildeAgainstAbsolutePaths() {
        let home = NSHomeDirectory()
        let candidates = RepoDiscoveryPlanner.candidates(
            repos: [DiscoveredRepo(path: "\(home)/repos/rai", name: "rai")],
            openPaths: ["~/repos/rai"]
        )
        XCTAssertTrue(candidates.isEmpty)
    }

    func testCandidatesKeepEverythingWhenNothingIsOpen() {
        let repos = [DiscoveredRepo(path: "/a/one", name: "one")]
        XCTAssertEqual(
            RepoDiscoveryPlanner.candidates(repos: repos, openPaths: []).map(\.path),
            ["/a/one"]
        )
    }

    // MARK: - Explicit path queries

    func testExplicitPathQueryExpandsTildeForms() {
        let home = NSHomeDirectory()
        XCTAssertEqual(RepoDiscoveryPlanner.explicitPathQuery("~"), home)
        XCTAssertEqual(RepoDiscoveryPlanner.explicitPathQuery("~/repos"), "\(home)/repos")
        XCTAssertEqual(RepoDiscoveryPlanner.explicitPathQuery(" /tmp/a/ "), "/tmp/a")
    }

    func testExplicitPathQueryRejectsNonPaths() {
        XCTAssertNil(RepoDiscoveryPlanner.explicitPathQuery("curator"))
        XCTAssertNil(RepoDiscoveryPlanner.explicitPathQuery("~user/repos"))
        XCTAssertNil(RepoDiscoveryPlanner.explicitPathQuery(""))
        XCTAssertNil(RepoDiscoveryPlanner.explicitPathQuery("   "))
    }

    // MARK: - Paths

    func testNormalizedCollapsesTrailingSlashAndDotSegments() {
        XCTAssertEqual(
            RepoDiscoveryPlanner.normalized("/tmp/a/"),
            RepoDiscoveryPlanner.normalized("/tmp/a")
        )
        XCTAssertEqual(RepoDiscoveryPlanner.normalized("/tmp/a/b/.."), "/tmp/a")
    }

    func testDisplayPathAbbreviatesHome() {
        XCTAssertEqual(
            RepoDiscoveryPlanner.displayPath("\(NSHomeDirectory())/repos/rai"),
            "~/repos/rai"
        )
    }
}
