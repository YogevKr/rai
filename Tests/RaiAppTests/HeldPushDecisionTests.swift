import RaiCore
import XCTest

@testable import RaiApp

final class HeldPushDecisionTests: XCTestCase {
    func testWaitsWhileUserIsActive() {
        XCTAssertEqual(
            HeldPushDecision.evaluate(
                paneStatus: .blocked, expectedStatus: .blocked,
                isSelectedOnMac: false, idleSeconds: 10, awayAfter: 120
            ),
            .wait
        )
    }

    func testPushesOnceUserIsAway() {
        XCTAssertEqual(
            HeldPushDecision.evaluate(
                paneStatus: .blocked, expectedStatus: .blocked,
                isSelectedOnMac: false, idleSeconds: 120, awayAfter: 120
            ),
            .push
        )
    }

    func testHandledAtTheDeskCancels() {
        // Status moved on (user answered the prompt): the phone never buzzes.
        XCTAssertEqual(
            HeldPushDecision.evaluate(
                paneStatus: .working, expectedStatus: .blocked,
                isSelectedOnMac: false, idleSeconds: 300, awayAfter: 120
            ),
            .cancel
        )
    }

    func testSelectedPaneCancels() {
        // Looking at the pane counts as handling it, same as the retraction
        // rule for delivered notifications.
        XCTAssertEqual(
            HeldPushDecision.evaluate(
                paneStatus: .blocked, expectedStatus: .blocked,
                isSelectedOnMac: true, idleSeconds: 300, awayAfter: 120
            ),
            .cancel
        )
    }

    func testClosedPaneCancels() {
        XCTAssertEqual(
            HeldPushDecision.evaluate(
                paneStatus: nil, expectedStatus: .blocked,
                isSelectedOnMac: false, idleSeconds: 300, awayAfter: 120
            ),
            .cancel
        )
    }

    func testDoneTransitionRestartedCancels() {
        // "Finished" held, then the user sent a new task from the desk: the
        // pane is working again, so the stale Finished push must die.
        XCTAssertEqual(
            HeldPushDecision.evaluate(
                paneStatus: .working, expectedStatus: .done,
                isSelectedOnMac: false, idleSeconds: 200, awayAfter: 120
            ),
            .cancel
        )
    }
}
