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

    @MainActor
    func testRemoteScanCreatesTheSharedSSHMaster() async throws {
        guard let labRoot = ProcessInfo.processInfo.environment["RAI_MACHINE_E2E_ROOT"],
              AppDataPaths.current.isolatedRoot?.resolvingSymlinksInPath().path
                == URL(fileURLWithPath: labRoot).resolvingSymlinksInPath().path else {
            throw XCTSkip("Requires the owned disposable SSH fixture and RAI_MACHINE_E2E_ROOT.")
        }
        let target = "rai-lab-1"
        let remoteRoot = "/tmp/rai-repo-scan-\(UUID().uuidString.lowercased())"
        let configuration = try RemoteConnection.sshConfigurationArguments(target: target)

        // The setup command uses ControlMaster=auto, so it does not leave a
        // master behind. The scanner must create one through Rai's helper.
        _ = try? await MachineCommandRunner.capture(
            binary: "/usr/bin/ssh",
            arguments: configuration + ["-O", "exit", target],
            timeout: 5
        )
        let setup = try await MachineCommandRunner.capture(
            binary: "/usr/bin/ssh",
            arguments: configuration + [
                "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                target, "mkdir", "-p", "\(remoteRoot)/alpha/.git",
            ],
            timeout: 5
        )
        XCTAssertEqual(setup.status, 0, String(decoding: setup.standardError, as: UTF8.self))
        addTeardownBlock {
            _ = try? await MachineCommandRunner.capture(
                binary: "/usr/bin/ssh",
                arguments: configuration + [
                    "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                    target, "rm", "-rf", remoteRoot,
                ],
                timeout: 5
            )
            _ = try? await MachineCommandRunner.capture(
                binary: "/usr/bin/ssh",
                arguments: configuration + ["-O", "exit", target],
                timeout: 5
            )
        }

        let repos = await RepoScanner.scan(
            roots: [remoteRoot], depth: 1, remoteTarget: target
        )
        XCTAssertEqual(repos.map(\.name), ["alpha"])

        let master = try await MachineCommandRunner.capture(
            binary: "/usr/bin/ssh",
            arguments: configuration + [
                "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                "-O", "check", target,
            ],
            timeout: 5
        )
        XCTAssertEqual(master.status, 0, "Remote scan must leave Rai's shared SSH master ready.")
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
