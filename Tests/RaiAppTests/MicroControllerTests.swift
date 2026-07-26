import RaiCore
@testable import RaiApp
import XCTest

final class MicroControllerTests: XCTestCase {
    func testAssignmentsAreMostRecentFirst() throws {
        func pane(_ id: String, revision: Int, status: String) throws -> Pane {
            let json = """
            {
              "pane_id":"\(id)","terminal_id":"term-\(id)",
              "workspace_id":"workspace","tab_id":"tab","focused":false,
              "cwd":"/tmp","agent":"codex","agent_status":"\(status)",
              "revision":\(revision)
            }
            """
            return try JSONDecoder().decode(Pane.self, from: Data(json.utf8))
        }

        let assignments = MicroControllerDecisions.assignments(from: [
            try pane("old", revision: 4, status: "idle"),
            try pane("new", revision: 9, status: "working"),
        ])
        XCTAssertEqual(assignments.map(\.paneID), ["new", "old"])
        XCTAssertEqual(assignments.map(\.status), [.working, .idle])
    }

    func testEventToIntentMapping() {
        XCTAssertEqual(
            MicroControllerDecisions.intent(for: .agentKey(index: 2, state: .press)),
            .selectSlot(2)
        )
        XCTAssertNil(
            MicroControllerDecisions.intent(for: .agentKey(index: 2, state: .release))
        )
        XCTAssertEqual(
            MicroControllerDecisions.intent(
                for: .joystick(direction: .left, state: .press)
            ),
            .focusPane("l")
        )
        XCTAssertNil(
            MicroControllerDecisions.intent(
                for: .joystick(direction: .left, state: .release)
            )
        )
        XCTAssertEqual(
            MicroControllerDecisions.intent(for: .encoder(.clockwise)),
            .stepSelection(1)
        )
        XCTAssertEqual(
            MicroControllerDecisions.intent(for: .encoder(.counterclockwise)),
            .stepSelection(-1)
        )
        XCTAssertEqual(
            MicroControllerDecisions.intent(for: .encoder(.press)),
            .openCommandPalette
        )
    }

    func testWisprAndUnboundCommandMapping() {
        XCTAssertEqual(
            MicroControllerDecisions.intent(
                for: .commandKey(id: "ACT10", state: .press)
            ),
            .wisprFlow(true)
        )
        XCTAssertEqual(
            MicroControllerDecisions.intent(
                for: .commandKey(id: "ACT10", state: .release)
            ),
            .wisprFlow(false)
        )
        XCTAssertNil(
            MicroControllerDecisions.intent(
                for: .commandKey(id: "ACT11", state: .press)
            )
        )
        XCTAssertEqual(
            MicroControllerDecisions.intent(
                for: .commandKey(id: "ACT06", state: .release)
            ),
            .unboundCommand(id: "ACT06", state: .release)
        )
    }

    func testEncoderSelectionUsesSlotOrderAndWraps() {
        let slots: [MicroSlotAssignment?] = [
            .init(paneID: "a", status: .working),
            nil,
            .init(paneID: "b", status: .blocked),
            .init(paneID: "c", status: .idle),
            nil,
            nil,
        ]
        XCTAssertEqual(
            MicroControllerDecisions.nextPaneID(
                in: slots, selectedPaneID: "a", step: 1
            ),
            "b"
        )
        XCTAssertEqual(
            MicroControllerDecisions.nextPaneID(
                in: slots, selectedPaneID: "a", step: -1
            ),
            "c"
        )
        XCTAssertEqual(
            MicroControllerDecisions.nextPaneID(
                in: slots, selectedPaneID: "outside", step: 1
            ),
            "a"
        )
    }

    func testStatusesPreserveEmptySlots() {
        let slots: [MicroSlotAssignment?] = [
            .init(paneID: "a", status: .working),
            nil,
            .init(paneID: "b", status: .done),
            nil, nil, nil,
        ]
        XCTAssertEqual(
            MicroControllerDecisions.statuses(from: slots),
            [.working, nil, .done, nil, nil, nil]
        )
    }
}
