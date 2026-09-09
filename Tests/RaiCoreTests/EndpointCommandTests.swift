import Foundation
import XCTest
@testable import RaiCore

final class EndpointCommandTests: XCTestCase {
    private func snapshot(_ changes: [String: Any] = [:]) throws -> HerdrEndpointSnapshot {
        var object: [String: Any] = [
            "boot_id": "boot", "revision": 2,
            "focused_workspace_id": "w1", "focused_tab_id": "w1:t1", "focused_pane_id": "w1:p1",
            "commands": [["command_id": "opaque", "description": "Lab command", "binding_label": "prefix+x"]],
            "workspaces": [["workspace_id": "w1"]],
            "tabs": [["workspace_id": "w1", "tab_id": "w1:t1"]],
            "panes": [["workspace_id": "w1", "tab_id": "w1:t1", "pane_id": "w1:p1"]],
        ]
        object.merge(changes) { _, next in next }
        return try JSONDecoder().decode(HerdrEndpointSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testInvocationRetainsContextAcrossFocusChangesAndBridgeRoundTrip() throws {
        let captured = try snapshot()
        let command = try XCTUnwrap(EndpointCommand(captured.commands[0]))
        let invocation = EndpointCommandInvocation(command: command, snapshot: captured)
        try invocation.validate(in: snapshot(["focused_pane_id": "w2:p2", "revision": 5]))
        let bridge = EndpointBridgeCommand.invoke(invocation)
        let decoded = try JSONDecoder().decode(EndpointBridgeCommand.self, from: JSONEncoder().encode(bridge))
        XCTAssertEqual(decoded, bridge)
        XCTAssertEqual(decoded.rpc.method, "command.invoke")
        XCTAssertEqual(decoded.rpc.params, ["command_id": .string("opaque"), "workspace_id": .string("w1"),
                                          "tab_id": .string("w1:t1"), "pane_id": .string("w1:p1")])
    }

    func testChangedCommandRestartAndRemovedOrMovedTargetsAreRejected() throws {
        let captured = try snapshot()
        let invocation = EndpointCommandInvocation(command: try XCTUnwrap(EndpointCommand(captured.commands[0])), snapshot: captured)
        let changes: [[String: Any]] = [
            ["boot_id": "restarted"], ["commands": []], ["panes": []], ["tabs": []], ["workspaces": []],
            ["commands": [["command_id": "opaque", "description": "Changed"]]],
            ["commands": [["command_id": "opaque"], ["command_id": "opaque"]]],
            ["panes": [["pane_id": "w1:p1", "tab_id": "w2:t1"]]],
            ["tabs": [["tab_id": "w1:t1", "workspace_id": "w2"]]],
        ]
        for change in changes { XCTAssertThrowsError(try invocation.validate(in: snapshot(change))) }
    }

    func testMalformedCommandIDsAreNotOffered() {
        XCTAssertNil(EndpointCommand(.object([:])))
        XCTAssertNil(EndpointCommand(.object(["command_id": .string("")])))
        XCTAssertNil(EndpointCommand(.object(["command_id": .string(String(repeating: "x", count: 4097))])))
    }
}
