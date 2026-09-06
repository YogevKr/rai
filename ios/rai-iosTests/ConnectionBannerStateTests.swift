import XCTest
@testable import rai

@MainActor
final class ConnectionBannerStateTests: XCTestCase {
    private final class Delay {
        var durations: [Duration] = []
        var waiters: [CheckedContinuation<Void, Error>] = []

        func sleep(_ duration: Duration) async throws {
            durations.append(duration)
            try await withCheckedThrowingContinuation { waiters.append($0) }
        }

        func finishNext() { waiters.removeFirst().resume() }
    }

    private let failure = ConnectionDiagnosis(
        message: "Connection lost", rawDetails: "test", action: .reconnect
    )

    func testBriefFailureNeverShowsBannerAfterRecovery() async {
        let delay = Delay()
        let state = ConnectionBannerState(sleep: delay.sleep)
        state.update(.failed(failure))
        await yieldTasks()
        XCTAssertEqual(delay.durations, [.seconds(3)])
        XCTAssertNil(state.diagnosis)
        state.update(.connected)
        delay.finishNext()
        await yieldTasks()
        XCTAssertNil(state.diagnosis, "A cancelled delay must not flash after recovery")
    }

    func testRetriesKeepTheOutageDeadlineAndUseTheLatestDiagnosis() async {
        let delay = Delay()
        let state = ConnectionBannerState(sleep: delay.sleep)
        state.update(.failed(failure))
        await yieldTasks()
        state.update(.connecting)
        let latest = ConnectionDiagnosis(message: "Mac unavailable", rawDetails: "test", action: .reconnect)
        state.update(.failed(latest))
        state.update(.connecting)
        XCTAssertNil(state.diagnosis)
        delay.finishNext()
        await yieldTasks()
        XCTAssertEqual(delay.durations.count, 1, "Retries must not restart the three-second delay")
        XCTAssertEqual(state.diagnosis, latest)
        state.update(.connected)
        XCTAssertNil(state.diagnosis)
    }

    func testOldDelayCannotShowBannerDuringANewOutage() async {
        let delay = Delay()
        let state = ConnectionBannerState(sleep: delay.sleep)
        state.update(.failed(failure))
        await yieldTasks()
        state.update(.connected)
        state.update(.failed(failure))
        await yieldTasks()
        delay.finishNext()
        await yieldTasks()
        XCTAssertNil(state.diagnosis)
        delay.finishNext()
        await yieldTasks()
        XCTAssertEqual(state.diagnosis, failure)
        state.update(.disconnected)
        XCTAssertNil(state.diagnosis)
    }

    func testPairingRepairShowsImmediatelyAndCancelsPendingDelay() async {
        let delay = Delay()
        let state = ConnectionBannerState(sleep: delay.sleep)
        state.update(.failed(failure))
        await yieldTasks()
        let repair = ConnectionDiagnosis(message: "Pair again", rawDetails: "test", action: .pairAgain)
        state.update(.failed(repair))
        XCTAssertEqual(state.diagnosis, repair)
        state.update(.connected)
        delay.finishNext()
        await yieldTasks()
        XCTAssertNil(state.diagnosis)
    }

    private func yieldTasks() async {
        for _ in 0..<10 { await Task.yield() }
    }
}
