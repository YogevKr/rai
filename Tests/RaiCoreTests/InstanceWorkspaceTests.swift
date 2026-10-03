import Foundation
import XCTest
@testable import RaiCore

final class InstanceWorkspaceTests: XCTestCase {
    func testEntriesKeepDuplicateWorkspaceIDsSeparateByEndpoint() throws {
        let first = MachineEndpoint(profileID: "one", session: "default")
        let second = MachineEndpoint(profileID: "two", session: "default")
        let machines = [
            MachineEntry(endpoint: first, label: "Remote One", health: .online),
            MachineEntry(endpoint: second, label: "Remote Two", health: .online),
        ]
        let snapshots = [
            first: try snapshot(label: "One", paneID: "w1:p1"),
            second: try snapshot(label: "Two", paneID: "w1:p1"),
        ]

        let entries = InstanceWorkspace.entries(machines: machines, snapshots: snapshots, excluding: nil)

        XCTAssertEqual(entries.map(\.id), [
            RaiWorkspaceReference(endpoint: first, workspaceID: "w1"),
            RaiWorkspaceReference(endpoint: second, workspaceID: "w1"),
        ])
        XCTAssertEqual(entries.map(\.instanceLabel), ["Remote One", "Remote Two"])
        XCTAssertEqual(entries.map { $0.tabs.first?.panes.first?.endpoint }, [first, second])
    }

    func testPrimaryInstanceIsExcluded() throws {
        let local = MachineEndpoint(session: "default")
        let machine = MachineEntry(endpoint: local, label: "This Mac", health: .online)
        let entries = InstanceWorkspace.entries(
            machines: [machine],
            snapshots: [local: try snapshot(label: "Local", paneID: "w1:p1")],
            excluding: local
        )
        XCTAssertTrue(entries.isEmpty)
    }

    private func snapshot(label: String, paneID: String) throws -> HerdrEndpointSnapshot {
        let value: [String: Any] = [
            "boot_id": "boot",
            "revision": 1,
            "workspaces": [[
                "workspace_id": "w1",
                "label": label,
                "active_tab_id": "w1:t1",
            ]],
            "tabs": [[
                "tab_id": "w1:t1",
                "workspace_id": "w1",
                "label": "Shell",
                "agent_status": "idle",
            ]],
            "panes": [[
                "pane_id": paneID,
                "workspace_id": "w1",
                "tab_id": "w1:t1",
            ]],
        ]
        return try JSONDecoder().decode(
            HerdrEndpointSnapshot.self,
            from: JSONSerialization.data(withJSONObject: value)
        )
    }
}
