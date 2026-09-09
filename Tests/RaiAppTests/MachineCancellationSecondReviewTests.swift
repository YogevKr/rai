import Darwin
import Foundation
import XCTest
@testable import RaiApp

final class MachineCancellationSecondReviewTests: XCTestCase {
    func testTimeoutStopsChildAfterParentAcceptsTermination() async throws {
        let marker = "/tmp/rai-command-cancel-review-" + UUID().uuidString
        var child: Int32 = 0
        defer {
            if child > 0 { Darwin.kill(child, SIGKILL) }
            try? FileManager.default.removeItem(atPath: marker)
        }
        do {
            _ = try await MachineCommandRunner.capture(binary: "/bin/sh", arguments: ["-c", "/bin/sh -c 'trap \"\" TERM; exec sleep 60' & echo $! > \"$1\"; wait", "sh", marker], timeout: 0.2)
            XCTFail("The parent must time out")
        } catch {}
        child = Int32(try String(contentsOfFile: marker).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        XCTAssertGreaterThan(child, 0)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNotEqual(Darwin.kill(child, 0), 0, "The command child survives because escalation checks only its exited parent.")
    }
}
