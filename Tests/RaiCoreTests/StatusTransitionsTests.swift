import RaiCore
import XCTest

final class StatusTransitionsTests: XCTestCase {
    func testDetectsTransitionsIntoBlockedAndDone() {
        XCTAssertEqual(
            StatusTransitions.detect(
                from: [
                    "pane-b": .working,
                    "pane-a": .idle,
                    "pane-c": .blocked,
                ],
                to: [
                    "pane-b": .done,
                    "pane-a": .blocked,
                    "pane-c": .blocked,
                ]
            ),
            [
                PaneStatusTransition(paneID: "pane-a", newStatus: .blocked),
                PaneStatusTransition(paneID: "pane-b", newStatus: .done),
            ]
        )
    }

    func testIgnoresUnchangedAndNonAttentionTransitions() {
        XCTAssertEqual(
            StatusTransitions.detect(
                from: [
                    "blocked": .blocked,
                    "done": .done,
                    "idle": .idle,
                    "working": .working,
                ],
                to: [
                    "blocked": .blocked,
                    "done": .done,
                    "idle": .working,
                    "working": .idle,
                ]
            ),
            []
        )
    }

    func testIgnoresAddedAndRemovedPanes() {
        XCTAssertEqual(
            StatusTransitions.detect(
                from: [
                    "removed": .working,
                    "existing": .working,
                ],
                to: [
                    "added": .blocked,
                    "existing": .working,
                ]
            ),
            []
        )
    }

    func testSameBlockedSnapshotDoesNotFireAgain() {
        let blocked = ["pane": AgentStatus.blocked]

        XCTAssertEqual(
            StatusTransitions.detect(from: ["pane": .working], to: blocked),
            [PaneStatusTransition(paneID: "pane", newStatus: .blocked)]
        )
        XCTAssertEqual(StatusTransitions.detect(from: blocked, to: blocked), [])
    }

    func testCanFireAgainAfterLeavingBlocked() {
        XCTAssertEqual(
            StatusTransitions.detect(
                from: ["pane": .working],
                to: ["pane": .blocked]
            ).count,
            1
        )
        XCTAssertEqual(
            StatusTransitions.detect(
                from: ["pane": .blocked],
                to: ["pane": .working]
            ),
            []
        )
        XCTAssertEqual(
            StatusTransitions.detect(
                from: ["pane": .working],
                to: ["pane": .blocked]
            ).count,
            1
        )
    }
}
