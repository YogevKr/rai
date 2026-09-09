import Darwin
import Foundation
import XCTest
@testable import RaiApp

@MainActor
final class MachineSetupCancellationReviewTests: XCTestCase {
    func testCancellationStopsInheritedPTYChild() async throws {
        let marker = "/tmp/rai-setup-cancel-review-" + UUID().uuidString
        let process = MachineSetupProcess(update: { _, _ in }, finish: { _ in })
        var child: Int32 = 0
        defer {
            process.cancel()
            if child > 0 { Darwin.kill(child, SIGKILL) }
            try? FileManager.default.removeItem(atPath: marker)
        }
        try process.start(binary: "/bin/sh", arguments: ["-c", "trap '' TERM; /bin/sh -c 'trap \"\" TERM; exec sleep 60' & echo $! > \"$1\"; wait", "sh", marker])
        for _ in 0..<100 {
            if let value = try? String(contentsOfFile: marker), let pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)) { child = pid; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(child, 0)
        process.cancel()
        try await Task.sleep(for: .seconds(3))
        XCTAssertNotEqual(Darwin.kill(child, 0), 0, "A setup child survives cancellation and keeps the PTY reader blocked.")
    }
    func testCancellationStopsChildAfterParentAlreadyExited() async throws {
        let marker = "/tmp/rai-setup-cancel-review-" + UUID().uuidString
        let process = MachineSetupProcess(update: { _, _ in }, finish: { _ in })
        var child: Int32 = 0
        defer {
            process.cancel()
            if child > 0 { Darwin.kill(child, SIGKILL) }
            try? FileManager.default.removeItem(atPath: marker)
        }
        try process.start(binary: "/bin/sh", arguments: ["-c", "/bin/sh -c 'trap \"\" TERM; exec sleep 60' & echo $! > \"$1\"; exit 0", "sh", marker])
        for _ in 0..<100 {
            if let value = try? String(contentsOfFile: marker), let pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)) { child = pid; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(child, 0)
        try await Task.sleep(for: .milliseconds(300))
        process.cancel()
        try await Task.sleep(for: .seconds(3))
        XCTAssertNotEqual(Darwin.kill(child, 0), 0, "A setup child survives cancellation and keeps the PTY reader blocked.")
    }
}
