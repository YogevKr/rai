import Foundation
import RaiCore
import XCTest
@testable import RaiApp

@MainActor
final class MachineTitleMonitorTests: XCTestCase {
    private func snapshot() throws -> SessionSnapshot {
        try JSONDecoder().decode(SessionSnapshot.self, from: Data(#"{"version":"0.9.3","protocol":22,"workspaces":[],"tabs":[],"panes":[],"layouts":[]}"#.utf8))
    }

    func testBurstCoalescesAndIdleDoesNotPoll() async throws {
        let source = try snapshot()
        var reads = 0
        var received = 0
        let updated = expectation(description: "title update")
        let monitor = MachineTitleMonitor(socketPath: "/unused.sock", bootID: "boot", delay: .milliseconds(10), read: {
            reads += 1
            return source
        }) { _ in received += 1; updated.fulfill() }
        defer { monitor.stop() }
        for _ in 0..<100 { monitor.requestRefresh() }
        await fulfillment(of: [updated], timeout: 2)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(received, 1)
    }

    func testEventDuringReadGetsOneTrailingRefresh() async throws {
        let source = try snapshot()
        var reads = 0
        var continuation: CheckedContinuation<SessionSnapshot, Never>?
        let reading = expectation(description: "first read started")
        let updated = expectation(description: "two updates")
        updated.expectedFulfillmentCount = 2
        let monitor = MachineTitleMonitor(socketPath: "/unused.sock", bootID: "boot", delay: .milliseconds(10), read: {
            reads += 1
            if reads == 1 {
                return await withCheckedContinuation { continuation = $0; reading.fulfill() }
            }
            return source
        }) { _ in updated.fulfill() }
        defer { monitor.stop() }
        monitor.requestRefresh()
        await fulfillment(of: [reading], timeout: 2)
        for _ in 0..<100 { monitor.requestRefresh() }
        continuation?.resume(returning: source)
        await fulfillment(of: [updated], timeout: 2)
        XCTAssertEqual(reads, 2)
    }

    func testStopRejectsLateSnapshotAndNewRefreshes() async throws {
        let source = try snapshot()
        var continuation: CheckedContinuation<SessionSnapshot, Never>?
        var received = 0
        var reads = 0
        let reading = expectation(description: "read started")
        let monitor = MachineTitleMonitor(socketPath: "/unused.sock", bootID: "boot", delay: .milliseconds(10), read: {
            reads += 1
            return await withCheckedContinuation { continuation = $0; reading.fulfill() }
        }) { _ in received += 1 }
        monitor.requestRefresh()
        await fulfillment(of: [reading], timeout: 2)
        monitor.stop()
        continuation?.resume(returning: source)
        monitor.requestRefresh()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(received, 0)
    }

    func testTransientReadFailureRecoversWithoutAnotherEvent() async throws {
        let source = try snapshot()
        var reads = 0
        let updated = expectation(description: "retried title update")
        let monitor = MachineTitleMonitor(socketPath: "/unused.sock", bootID: "boot", delay: .milliseconds(10), read: {
            reads += 1
            if reads == 1 { throw URLError(.networkConnectionLost) }
            return source
        }) { _ in updated.fulfill() }
        defer { monitor.stop() }
        monitor.requestRefresh()
        await fulfillment(of: [updated], timeout: 2)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(reads, 2)
    }

    func testPersistentReadFailureStopsAfterThreeAttempts() async throws {
        var reads = 0
        let exhausted = expectation(description: "retry limit")
        let monitor = MachineTitleMonitor(socketPath: "/unused.sock", bootID: "boot", delay: .milliseconds(10), read: {
            reads += 1
            if reads == 3 { exhausted.fulfill() }
            throw URLError(.networkConnectionLost)
        }) { _ in XCTFail("Failed reads cannot supply titles") }
        defer { monitor.stop() }
        monitor.requestRefresh()
        await fulfillment(of: [exhausted], timeout: 2)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(reads, 3)
    }
}
