import Foundation
import RaiCore
import XCTest
@testable import RaiApp

@MainActor
final class MachineDirectoryTests: XCTestCase {
    func testRefreshUsesOnlyCatalogAndSessionReads() async throws {
        var calls: [[String]] = []
        let directory = MachineDirectory { arguments in
            calls.append(arguments)
            return Data((arguments.first == "machine" ? "[]" : "{\"sessions\":[]}").utf8)
        }
        await directory.perform(.init(revision: UUID(), operation: .refresh))
        XCTAssertNil(directory.state.error)
        XCTAssertFalse(directory.state.busy)
        XCTAssertEqual(calls, [["machine", "list", "--json"], ["session", "list", "--json"]])
    }

    func testCatalogChangesInvalidateQueuedWritesAndDuplicateRequestsDoNotReplay() async {
        var calls: [[String]] = []
        let directory = MachineDirectory { arguments in
            calls.append(arguments)
            return Data((arguments.first == "machine" ? "[]" : "{\"sessions\":[]}").utf8)
        }
        let oldRevision = directory.state.revision
        let refresh = MachineRequest(revision: oldRevision, operation: .refresh)
        await directory.perform(refresh)
        await directory.perform(refresh)
        XCTAssertEqual(calls.count, 2)
        await directory.perform(.init(revision: oldRevision, operation: .remove(profileID: String(repeating: "a", count: 32))))
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(directory.state.error, "The machine list changed. Review the machines again.")
    }

    func testDisabledMachinesNeverOpenConnectionsAndCannotResolveAResource() async {
        let json = "[{\"id\":\"0123456789abcdef0123456789abcdef\",\"label\":\"Disabled\",\"target\":\"never-contact.invalid\",\"session\":\"default\",\"enabled\":false,\"selected\":false}]"
        let directory = MachineDirectory { arguments in Data((arguments.first == "machine" ? json : "{\"sessions\":[]}").utf8) }
        await directory.perform(.init(revision: directory.state.revision, operation: .refresh))
        let entry = directory.state.entries[0]
        XCTAssertEqual(entry.health, .disabled)
        XCTAssertNil(entry.connectionID)
        XCTAssertNil(directory.resolve(entry.endpoint, connectionID: "guessed"))
        await directory.perform(.init(revision: directory.state.revision, operation: .reconnect(entry.endpoint)))
        XCTAssertEqual(directory.state.error, "Enable this machine before connecting.")
    }

    func testCLIErrorReachesDirectoryWithoutDroppingPreviousState() async {
        let directory = MachineDirectory { _ in throw MachineCatalogError.invalid("Herdr 0.8 does not support machine list.") }
        await directory.perform(.init(revision: directory.state.revision, operation: .refresh))
        XCTAssertEqual(directory.state.error, "Herdr 0.8 does not support machine list.")
        XCTAssertFalse(directory.state.busy)
    }

    func testSetupRequiresAnExplicitAnswerForEachPrompt() async throws {
        let prompted = expectation(description: "first prompt")
        let nextPrompted = expectation(description: "second prompt")
        let finished = expectation(description: "setup finished")
        var prompts: [UUID] = []
        var output = ""
        var exitStatus: Int32?
        let setup = MachineSetupProcess { text, prompt in
            output = text
            if let prompt, !prompts.contains(prompt) {
                prompts.append(prompt)
                if prompts.count == 1 { prompted.fulfill() } else { nextPrompted.fulfill() }
            }
        } finish: { status in exitStatus = status; finished.fulfill() }
        try setup.start(binary: "/bin/sh", arguments: ["-c", "test -t 0 || exit 7; printf 'Install test fixture? [Y/n] '; read first; printf '\\nFirst=%s\\nReplace test fixture? [y/N] ' \"$first\"; read second; printf '\\nSecond=%s\\n' \"$second\""])
        await fulfillment(of: [prompted], timeout: 3)
        XCTAssertNil(exitStatus)
        let first = try XCTUnwrap(prompts.first)
        XCTAssertThrowsError(try setup.answer(promptID: UUID(), approve: true))
        try setup.answer(promptID: first, approve: true)
        XCTAssertThrowsError(try setup.answer(promptID: first, approve: true))
        await fulfillment(of: [nextPrompted], timeout: 3)
        XCTAssertNil(exitStatus)
        XCTAssertTrue(output.contains("First=yes"))
        try setup.answer(promptID: XCTUnwrap(prompts.last), approve: false)
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(exitStatus, 0)
    }

    func testCancelSetupNeverSuppliesDefaultApproval() async throws {
        let prompted = expectation(description: "prompt")
        let finished = expectation(description: "canceled")
        var status: Int32?
        let setup = MachineSetupProcess { _, prompt in if prompt != nil { prompted.fulfill() } }
            finish: { status = $0; finished.fulfill() }
        try setup.start(binary: "/bin/sh", arguments: ["-c", "printf 'Install fixture? [Y/n] '; read answer; exit 42"])
        await fulfillment(of: [prompted], timeout: 3)
        setup.cancel()
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(status, -1)
    }

    func testTruncatedSetupOutputCannotHideEarlierEffectsAndAcceptApproval() async throws {
        let truncated = expectation(description: "output limit")
        var reported = false
        var prompt: UUID?
        let setup = MachineSetupProcess { text, nextPrompt in
            prompt = nextPrompt
            if text.hasPrefix("Output exceeded"), !reported { reported = true; truncated.fulfill() }
        } finish: { _ in }
        defer { setup.cancel() }
        try setup.start(binary: "/bin/sh", arguments: ["-c", "head -c 70000 /dev/zero | tr '\\000' x; printf '\\nInstall fixture? [Y/n] '; read answer"])
        await fulfillment(of: [truncated], timeout: 3)
        XCTAssertTrue(setup.outputTruncated)
        XCTAssertNil(prompt)
        XCTAssertThrowsError(try setup.answer(promptID: UUID(), approve: true))
    }
}
