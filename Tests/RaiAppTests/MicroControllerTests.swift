import RaiCore
@testable import RaiApp
import XCTest

final class MicroControllerTests: XCTestCase {
    func testAssignmentsFollowSnapshotSidebarOrder() throws {
        let json = """
        {
          "version":"1","protocol":1,
          "focused_workspace_id":null,"focused_tab_id":null,"focused_pane_id":null,
          "workspaces":[
            {
              "workspace_id":"second","number":1,"label":"Second","focused":false,
              "pane_count":1,"tab_count":1,"active_tab_id":"second-tab",
              "agent_status":"idle","worktree":null
            },
            {
              "workspace_id":"first","number":0,"label":"First","focused":false,
              "pane_count":3,"tab_count":2,"active_tab_id":"first-tab",
              "agent_status":"working","worktree":null
            }
          ],
          "tabs":[
            {
              "tab_id":"first-tab","workspace_id":"first","number":0,
              "label":"First tab","focused":false,"pane_count":2,
              "agent_status":"working"
            },
            {
              "tab_id":"second-tab","workspace_id":"second","number":1,
              "label":"Second tab","focused":false,"pane_count":1,
              "agent_status":"idle"
            },
            {
              "tab_id":"last-tab","workspace_id":"first","number":2,
              "label":"Last tab","focused":false,"pane_count":1,
              "agent_status":"blocked"
            }
          ],
          "panes":[
            {
              "pane_id":"last","terminal_id":"term-last",
              "workspace_id":"first","tab_id":"last-tab","focused":false,
              "cwd":"/tmp","agent":"codex","agent_status":"blocked","revision":99
            },
            {
              "pane_id":"second","terminal_id":"term-second",
              "workspace_id":"second","tab_id":"second-tab","focused":false,
              "cwd":"/tmp","agent":"codex","agent_status":"idle","revision":1
            },
            {
              "pane_id":"first","terminal_id":"term-first",
              "workspace_id":"first","tab_id":"first-tab","focused":false,
              "cwd":"/tmp","agent":"codex","agent_status":"working","revision":50
            },
            {
              "pane_id":"first-next","terminal_id":"term-first-next",
              "workspace_id":"first","tab_id":"first-tab","focused":false,
              "cwd":"/tmp","agent":"codex","agent_status":"done","revision":100
            }
          ],
          "layouts":[]
        }
        """
        let snapshot = try JSONDecoder().decode(
            SessionSnapshot.self,
            from: Data(json.utf8)
        )

        let assignments = MicroControllerDecisions.assignments(from: snapshot)
        XCTAssertEqual(
            assignments.map(\.paneID),
            ["second", "first", "first-next", "last"]
        )
        XCTAssertEqual(
            assignments.map(\.status),
            [.idle, .working, .done, .blocked]
        )
    }

    func testEventToIntentMapping() {
        let bindings = MicroBindings.default
        XCTAssertEqual(
            MicroControllerDecisions.intent(
                for: .agentKey(index: 2, state: .press),
                bindings: bindings
            ),
            .action(.selectSlot(2), state: .press)
        )
        XCTAssertNil(
            MicroControllerDecisions.intent(
                for: .agentKey(index: 2, state: .release),
                bindings: bindings
            )
        )
        XCTAssertEqual(
            MicroControllerDecisions.intent(
                for: .joystick(direction: .left, state: .press),
                bindings: bindings
            ),
            .action(.focusPane("l"), state: .press)
        )
        XCTAssertNil(
            MicroControllerDecisions.intent(
                for: .joystick(direction: .left, state: .release),
                bindings: bindings
            )
        )
        XCTAssertEqual(
            MicroControllerDecisions.intent(
                for: .encoder(.clockwise),
                bindings: bindings
            ),
            .action(.prevAgent, state: .press)
        )
        XCTAssertEqual(
            MicroControllerDecisions.intent(
                for: .encoder(.counterclockwise),
                bindings: bindings
            ),
            .action(.nextAgent, state: .press)
        )
        XCTAssertEqual(
            MicroControllerDecisions.intent(
                for: .encoder(.press),
                bindings: bindings
            ),
            .action(.commandPalette, state: .press)
        )
    }

    func testWisprAndUnboundCommandMapping() {
        let bindings = MicroBindings.default
        XCTAssertEqual(
            MicroControllerDecisions.intent(
                for: .commandKey(id: "ACT10", state: .press),
                bindings: bindings
            ),
            .action(.wisprFlow, state: .press)
        )
        XCTAssertEqual(
            MicroControllerDecisions.intent(
                for: .commandKey(id: "ACT10", state: .release),
                bindings: bindings
            ),
            .action(.wisprFlow, state: .release)
        )
        XCTAssertEqual(
            MicroControllerDecisions.intent(
                for: .commandKey(id: "ACT11", state: .press),
                bindings: bindings
            ),
            .action(.sendReturn, state: .press)
        )
        XCTAssertNil(
            MicroControllerDecisions.intent(
                for: .commandKey(id: "ACT11", state: .release),
                bindings: bindings
            )
        )
        XCTAssertEqual(
            MicroControllerDecisions.intent(
                for: .commandKey(id: "ACT06", state: .press),
                bindings: bindings
            ),
            .action(.none, state: .press)
        )
    }

    func testCustomBindingOverridesDefault() {
        let bindings = MicroBindings.default
        bindings[.commandKey("ACT06")] = .customKeys("C-z")
        XCTAssertEqual(
            MicroControllerDecisions.intent(
                for: .commandKey(id: "ACT06", state: .press),
                bindings: bindings
            ),
            .action(.customKeys("C-z"), state: .press)
        )
        XCTAssertNil(
            MicroControllerDecisions.intent(
                for: .commandKey(id: "ACT06", state: .release),
                bindings: bindings
            )
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
