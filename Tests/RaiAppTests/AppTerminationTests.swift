import AppKit
import XCTest
@testable import RaiApp

@MainActor
final class AppTerminationTests: XCTestCase {
    func testUpdateQuitRunsOutsideTheCallingTask() async {
        let terminated = expectation(description: "termination requested")
        var callReturned = false
        var terminationCount = 0
        await Task { @MainActor in
            AppTermination.schedule {
                XCTAssertTrue(callReturned)
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertTrue(withUnsafeCurrentTask { $0 == nil })
                terminationCount += 1
                terminated.fulfill()
            }
            XCTAssertEqual(terminationCount, 0)
            callReturned = true
        }.value
        await fulfillment(of: [terminated], timeout: 2)
        XCTAssertEqual(terminationCount, 1)
    }

    func testRepeatedQuitWaitsForOneCleanupThenAllowsTermination() async {
        let coordinator = AppTerminationCoordinator(timeout: .seconds(2))
        let started = expectation(description: "cleanup started")
        let finished = expectation(description: "quit retried")
        var resume: CheckedContinuation<Void, Never>?
        var cleanups = 0
        let shutdown: @MainActor () async -> Void = {
            cleanups += 1
            await withCheckedContinuation { resume = $0; started.fulfill() }
        }
        let terminate: @MainActor () -> Void = {
            XCTAssertEqual(coordinator.request(shutdown: shutdown, reply: {}), .terminateNow)
            XCTAssertTrue(withUnsafeCurrentTask { $0 == nil })
            finished.fulfill()
        }
        XCTAssertEqual(coordinator.request(shutdown: shutdown, reply: terminate), .terminateLater)
        await fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(coordinator.request(shutdown: shutdown, reply: terminate), .terminateLater)
        XCTAssertEqual(cleanups, 1)
        resume?.resume()
        await fulfillment(of: [finished], timeout: 1)
    }

    func testStalledCleanupCannotPreventQuitOrScheduleItTwice() async {
        let coordinator = AppTerminationCoordinator(timeout: .milliseconds(50))
        let started = expectation(description: "stalled cleanup started")
        let finished = expectation(description: "deadline retried quit")
        var resume: CheckedContinuation<Void, Never>?
        var quits = 0
        XCTAssertEqual(coordinator.request(shutdown: {
            await withCheckedContinuation { resume = $0; started.fulfill() }
        }, reply: {
            quits += 1
            finished.fulfill()
        }), .terminateLater)
        await fulfillment(of: [started, finished], timeout: 1)
        XCTAssertEqual(coordinator.request(shutdown: {}, reply: {}), .terminateNow)
        resume?.resume()
        await Task.yield()
        XCTAssertEqual(quits, 1)
    }
}
