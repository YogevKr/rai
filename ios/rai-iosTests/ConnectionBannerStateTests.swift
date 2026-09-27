import XCTest
import SwiftUI
import UIKit
@testable import rai

@MainActor
final class ConnectionBannerStateTests: XCTestCase {
    @MainActor
    private final class Delay {
        var durations: [Duration] = []
        var waiters: [CheckedContinuation<Void, Error>] = []
        private var onStart: (() -> Void)?

        func sleep(_ duration: Duration) async throws {
            durations.append(duration)
            try await withCheckedThrowingContinuation {
                waiters.append($0)
                onStart?()
            }
        }

        func waitForPending(_ count: Int = 1) async {
            guard waiters.count < count else { return }
            let started = XCTestExpectation(description: "Delay registered its continuation")
            onStart = { [weak self] in
                guard let self, self.waiters.count >= count else { return }
                self.onStart = nil
                started.fulfill()
            }
            defer { onStart = nil }
            let result = await XCTWaiter.fulfillment(of: [started], timeout: 5)
            XCTAssertEqual(result, .completed)
        }

        func finishNext() {
            guard !waiters.isEmpty else {
                XCTFail("Delay must start before the test completes it")
                return
            }
            waiters.removeFirst().resume()
        }
    }

    private let failure = ConnectionDiagnosis(
        message: "Connection lost", rawDetails: "test", action: .reconnect
    )

    func testBriefFailureNeverShowsBannerAfterRecovery() async {
        let delay = Delay()
        let state = ConnectionBannerState(sleep: delay.sleep)
        state.update(.failed(failure))
        await delay.waitForPending()
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
        await delay.waitForPending()
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
        await delay.waitForPending()
        state.update(.connected)
        state.update(.failed(failure))
        await delay.waitForPending(2)
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
        await delay.waitForPending()
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

    func testCompactBannerWithLongHostAndLargeText() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        let diagnosis = ConnectionDiagnosis(
            message: "Connection to a-long-mac-name.example-tailnet.ts.net failed",
            rawDetails: "Synthetic transport error",
            action: .reconnect
        )
        for size in [DynamicTypeSize.large, .accessibility3] {
            let host = UIHostingController(rootView: ConnectionIssueBar(
                diagnosis: diagnosis,
                isReconnecting: true,
                lastSnapshotAt: Date().addingTimeInterval(-12),
                recover: {}
            )
                .environment(\.dynamicTypeSize, size)
                .preferredColorScheme(.dark))
            // Measure the inset's content without the hosting window's
            // status bar and home-indicator safe areas.
            host.safeAreaRegions = []
            window.rootViewController = host
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(100))
            let fitting = host.sizeThatFits(in: CGSize(width: 320, height: 1_000))
            XCTAssertLessThanOrEqual(fitting.width, 320)
            XCTAssertLessThan(fitting.height, size.isAccessibilitySize ? 280 : 120)
            host.view.frame = CGRect(origin: .zero, size: fitting)
            host.view.layoutIfNeeded()
            let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            })
            attachment.name = "Connection banner \(size)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
