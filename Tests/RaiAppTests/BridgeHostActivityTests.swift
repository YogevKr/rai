import Foundation
import Network
import XCTest
@testable import RaiApp

final class BridgeHostActivityTests: XCTestCase {
    func testHostActivityPreventsAppNapWithoutPreventingIdleSleep() throws {
        let processInfo = RecordingActivityProcessInfo()
        let listener = try NWListener(using: .tcp, on: .any)
        let activity = BridgeHostActivity(listener: listener, processInfo: processInfo) { _ in }
        withExtendedLifetime(activity) {
            XCTAssertEqual(processInfo.startedOptions, [.userInitiatedAllowingIdleSystemSleep])
            XCTAssertFalse(processInfo.startedOptions[0].contains(.idleSystemSleepDisabled))
            XCTAssertFalse(processInfo.startedOptions[0].contains(.idleDisplaySleepDisabled))
            XCTAssertEqual(processInfo.endedTokens.count, 0)
        }
        activity.stop()
        activity.stop()
        XCTAssertEqual(processInfo.endedTokens.count, 1)
        XCTAssertTrue(processInfo.endedTokens[0] === processInfo.startedTokens[0])
    }

    func testListenerBindFailureReleasesActivityWhileOwnerRemainsAlive() async throws {
        let occupied = try NWListener(using: .tcp, on: .any)
        occupied.newConnectionHandler = { $0.cancel() }
        let ready = expectation(description: "occupied listener ready")
        occupied.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        occupied.start(queue: DispatchQueue(label: "rai.test.occupied-listener"))
        defer { occupied.cancel() }
        await fulfillment(of: [ready], timeout: 3)

        let processInfo = RecordingActivityProcessInfo()
        let conflicting = try NWListener(using: .tcp, on: try XCTUnwrap(occupied.port))
        conflicting.newConnectionHandler = { $0.cancel() }
        let failed = expectation(description: "listener binding failed")
        let activity = BridgeHostActivity(listener: conflicting, processInfo: processInfo) { state in
            if case .failed(let error) = state {
                XCTAssertEqual(error, .posix(.EADDRINUSE))
                failed.fulfill()
            }
        }
        conflicting.start(queue: DispatchQueue(label: "rai.test.conflicting-listener"))
        defer { conflicting.cancel(); activity.stop() }
        await fulfillment(of: [failed], timeout: 3)
        XCTAssertEqual(processInfo.endedTokens.count, 1)
        XCTAssertTrue(processInfo.endedTokens[0] === processInfo.startedTokens[0])
        activity.stop()
        XCTAssertEqual(processInfo.endedTokens.count, 1)
    }

    func testListenerCancellationReleasesActivityWhileOwnerRemainsAlive() async throws {
        let processInfo = RecordingActivityProcessInfo()
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { $0.cancel() }
        let ready = expectation(description: "listener ready")
        let cancelled = expectation(description: "listener cancelled")
        let activity = BridgeHostActivity(listener: listener, processInfo: processInfo) { state in
            if case .ready = state { ready.fulfill() }
            if case .cancelled = state { cancelled.fulfill() }
        }
        listener.start(queue: DispatchQueue(label: "rai.test.cancelled-listener"))
        defer { listener.cancel(); activity.stop() }
        await fulfillment(of: [ready], timeout: 3)
        XCTAssertEqual(processInfo.endedTokens.count, 0)
        listener.cancel()
        await fulfillment(of: [cancelled], timeout: 3)
        XCTAssertEqual(processInfo.endedTokens.count, 1)
        XCTAssertTrue(processInfo.endedTokens[0] === processInfo.startedTokens[0])
    }
}

private final class RecordingActivityProcessInfo: ProcessInfo, @unchecked Sendable {
    private let lock = NSLock()
    private var options: [ProcessInfo.ActivityOptions] = []
    private var started: [NSObject] = []
    private var ended: [NSObject] = []
    var startedOptions: [ProcessInfo.ActivityOptions] { lock.withLock { options } }
    var startedTokens: [NSObject] { lock.withLock { started } }
    var endedTokens: [NSObject] { lock.withLock { ended } }

    override func beginActivity(options: ProcessInfo.ActivityOptions, reason: String) -> NSObjectProtocol {
        let token = NSObject()
        lock.withLock {
            self.options.append(options)
            started.append(token)
        }
        return token
    }

    override func endActivity(_ activity: NSObjectProtocol) {
        lock.withLock { ended.append(activity as! NSObject) }
    }
}
