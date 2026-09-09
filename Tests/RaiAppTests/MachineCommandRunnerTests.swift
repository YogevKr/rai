import Foundation
import XCTest
@testable import RaiApp

final class MachineCommandRunnerTests: XCTestCase {
    func testAlreadyCancelledCommandCannotCreateAFile() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("rai-cancelled-command-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let command = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MachineCommandRunner.capture(binary: "/usr/bin/touch", arguments: [marker.path])
        }
        do { _ = try await command.value; XCTFail("Cancellation must prevent command launch.") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testAlreadyCancelledCommandDoesNotAttemptToLaunchAnInvalidBinary() async throws {
        let missingBinary = FileManager.default.temporaryDirectory.appendingPathComponent("rai-missing-command-\(UUID().uuidString)")
        let command = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MachineCommandRunner.capture(binary: missingBinary.path, arguments: [])
        }
        do { _ = try await command.value; XCTFail("Cancellation must prevent command launch.") }
        catch { XCTAssertTrue(error is CancellationError, "Cancellation must precede executable validation: \(error)") }
    }

    func testDefaultEnvironmentPreservesTheSelectedHerdrConfiguration() async throws {
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let result = try await MachineCommandRunner.capture(binary: "/usr/bin/printenv", arguments: ["PATH"])
        XCTAssertEqual(String(decoding: result.standardOutput, as: UTF8.self).trimmingCharacters(in: .newlines), inherited)
        let override = try await MachineCommandRunner.capture(binary: "/usr/bin/printenv", arguments: ["RAI_TEST_MARKER"],
            environment: ["RAI_TEST_MARKER": "isolated"])
        XCTAssertEqual(String(decoding: override.standardOutput, as: UTF8.self), "isolated\n")
    }

    func testBothOutputStreamsDrainWithoutDeadlock() async throws {
        let result = try await MachineCommandRunner.capture(binary: "/bin/sh", arguments: ["-c", "dd if=/dev/zero bs=1024 count=96 >&2 2>/dev/null; printf done"], timeout: 2)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.standardError.count, 96 * 1024)
        XCTAssertEqual(String(decoding: result.standardOutput, as: UTF8.self), "done")
    }

    func testIgnoredTerminationAndInheritedPipeCannotBlockCompletion() async throws {
        let start = Date()
        do {
            _ = try await MachineCommandRunner.capture(binary: "/bin/sh", arguments: ["-c", "trap '' TERM; while :; do sleep 1; done"], timeout: 0.1)
            XCTFail("The timeout must fail.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        let result = try await MachineCommandRunner.capture(binary: "/bin/sh", arguments: ["-c", "sleep 1 & printf complete"], timeout: 0.5)
        XCTAssertEqual(String(decoding: result.standardOutput, as: UTF8.self), "complete")
    }

    func testCancellationAndUnboundedOutputStopTheCommand() async throws {
        let command = Task { try await MachineCommandRunner.capture(binary: "/bin/sleep", arguments: ["10"], timeout: 10) }
        command.cancel()
        do { _ = try await command.value; XCTFail("Cancellation must fail.") }
        catch { XCTAssertTrue(error is CancellationError) }
        do {
            _ = try await MachineCommandRunner.capture(binary: "/usr/bin/yes", arguments: [], timeout: 2)
            XCTFail("Output must remain bounded.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("too large")) }
    }
}
