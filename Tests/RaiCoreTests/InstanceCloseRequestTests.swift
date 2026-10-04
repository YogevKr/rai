import Foundation
import XCTest
@testable import RaiCore

final class InstanceCloseRequestTests: XCTestCase {
    func testTabCloseCapturesEndpointIdentityAndValidatesResources() throws {
        let endpoint = MachineEndpoint(profileID: "machine", session: "default")
        let snapshot = try Self.snapshot()
        let workspace = try XCTUnwrap(
            InstanceWorkspace.entries(
                machines: [MachineEntry(endpoint: endpoint, label: "Cloud", connectionID: "connection", health: .online)],
                snapshots: [endpoint: snapshot],
                excluding: nil
            ).first
        )
        let tab = try XCTUnwrap(workspace.tabs.first)
        let request = try InstanceCloseRequest(workspace: workspace, tabID: tab.id)

        XCTAssertEqual(request.method, "tab.close")
        XCTAssertEqual(request.params["tab_id"], JSONValue.string(tab.id))
        XCTAssertNoThrow(try request.validate(snapshot))

        var changed = snapshot
        changed = try Self.snapshot(bootID: "new-boot")
        XCTAssertThrowsError(try request.validate(changed))
    }

    func testWorkspaceCloseCapturesAllTabsAndUsesReviewableParams() throws {
        let endpoint = MachineEndpoint(profileID: "machine", session: "default")
        let snapshot = try Self.snapshot()
        let workspace = try XCTUnwrap(
            InstanceWorkspace.entries(
                machines: [MachineEntry(endpoint: endpoint, label: "Cloud", connectionID: "connection", health: .online)],
                snapshots: [endpoint: snapshot],
                excluding: nil
            ).first
        )
        let request = try InstanceCloseRequest(workspace: workspace)

        XCTAssertEqual(request.method, "workspace.close")
        XCTAssertEqual(request.params["workspace_id"], JSONValue.string("w1"))
        XCTAssertEqual(request.params["close_group"], JSONValue.bool(false))
        XCTAssertNoThrow(try request.validate(snapshot))
    }

    func testOneTabWorkspaceCanBeClosedAsAWorkspace() throws {
        let endpoint = MachineEndpoint(profileID: "machine", session: "default")
        let snapshot = try Self.snapshot(oneTab: true)
        let workspace = try XCTUnwrap(
            InstanceWorkspace.entries(
                machines: [MachineEntry(endpoint: endpoint, label: "Cloud", connectionID: "connection", health: .online)],
                snapshots: [endpoint: snapshot],
                excluding: nil
            ).first
        )
        XCTAssertEqual(workspace.tabs.count, 1)

        let request = try InstanceCloseRequest(workspace: workspace)

        XCTAssertEqual(request.method, "workspace.close")
        XCTAssertNoThrow(try request.validate(snapshot))
    }

    private static func snapshot(bootID: String = "boot", oneTab: Bool = false) throws -> HerdrEndpointSnapshot {
        let tabs: [[String: Any]] = oneTab
            ? [["tab_id": "w1:t1", "workspace_id": "w1", "label": "One"]]
            : [
                ["tab_id": "w1:t1", "workspace_id": "w1", "label": "One"],
                ["tab_id": "w1:t2", "workspace_id": "w1", "label": "Two"],
            ]
        let panes: [[String: Any]] = oneTab
            ? [["pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1"]]
            : [
                ["pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1"],
                ["pane_id": "w1:p2", "workspace_id": "w1", "tab_id": "w1:t2"],
            ]
        let value: [String: Any] = [
            "boot_id": bootID,
            "revision": 1,
            "workspaces": [["workspace_id": "w1", "label": "Cloud"]],
            "tabs": tabs,
            "panes": panes,
        ]
        return try JSONDecoder().decode(
            HerdrEndpointSnapshot.self,
            from: JSONSerialization.data(withJSONObject: value)
        )
    }
}
