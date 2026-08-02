import XCTest
@testable import RaiApp
@testable import RaiCore

final class RepoScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rai-repo-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    func testFindsClonesAndLinkedWorktreesButNotPlainDirectories() async throws {
        try makeClone("alpha")
        try makeLinkedWorktree("beta")
        try makeDirectory("notes")

        let repos = await RepoScanner.scan(roots: [root.path], depth: 1, remoteTarget: nil)

        XCTAssertEqual(repos.map(\.name), ["alpha", "beta"])
    }

    func testDoesNotDescendIntoACheckout() async throws {
        try makeClone("outer")
        // A vendored dependency inside a repo is part of that repo, not a
        // separate space worth offering.
        try makeClone("outer/vendor")

        let repos = await RepoScanner.scan(roots: [root.path], depth: 3, remoteTarget: nil)

        XCTAssertEqual(repos.map(\.name), ["outer"])
    }

    func testDepthControlsHowFarBelowARootACheckoutMaySit() async throws {
        try makeDirectory("work")
        try makeClone("work/nested")

        let shallow = await RepoScanner.scan(roots: [root.path], depth: 1, remoteTarget: nil)
        XCTAssertTrue(shallow.isEmpty)

        let deeper = await RepoScanner.scan(roots: [root.path], depth: 2, remoteTarget: nil)
        XCTAssertEqual(deeper.map(\.name), ["nested"])
    }

    func testMissingRootIsNotAnError() async {
        let repos = await RepoScanner.scan(
            roots: [root.appendingPathComponent("gone").path],
            depth: 1,
            remoteTarget: nil
        )
        XCTAssertTrue(repos.isEmpty)
    }

    func testNoRootsScansNothing() async {
        let repos = await RepoScanner.scan(roots: ["  "], depth: 1, remoteTarget: nil)
        XCTAssertTrue(repos.isEmpty)
    }

    // MARK: - Fixtures

    private func makeDirectory(_ relative: String) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(relative),
            withIntermediateDirectories: true
        )
    }

    private func makeClone(_ relative: String) throws {
        try makeDirectory("\(relative)/.git")
    }

    private func makeLinkedWorktree(_ relative: String) throws {
        try makeDirectory(relative)
        let marker = root.appendingPathComponent("\(relative)/.git")
        try "gitdir: /elsewhere/.git/worktrees/\(relative)\n"
            .write(to: marker, atomically: true, encoding: .utf8)
    }
}
