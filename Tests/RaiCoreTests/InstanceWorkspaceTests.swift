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

    func testTabUsesLocalDisplayFallbacks() throws {
        let endpoint = MachineEndpoint(profileID: "remote", session: "default")
        let machine = MachineEntry(endpoint: endpoint, label: "Remote", health: .online)
        let entries = InstanceWorkspace.entries(
            machines: [machine],
            snapshots: [endpoint: try snapshot(
                label: "Space",
                paneID: "w1:p1",
                tabLabel: "1",
                cwd: "/Users/yogev/projects/rai"
            )],
            excluding: nil
        )

        XCTAssertEqual(entries.first?.tabs.first?.label, "shell")
        XCTAssertEqual(entries.first?.tabs.first?.context, "rai")
    }

    func testTabKeepsCustomLabelAndPrefersTitlesOverAgentNames() throws {
        let endpoint = MachineEndpoint(profileID: "remote", session: "default")
        let machine = MachineEntry(endpoint: endpoint, label: "Remote", health: .online)
        for (label, expected) in [("Review", "Review"), ("1", "Fix tests"), ("", "Fix tests")] {
            let entries = InstanceWorkspace.entries(
                machines: [machine],
                snapshots: [endpoint: try snapshot(
                    label: "Space", paneID: "w1:p1", tabLabel: label,
                    agent: "codex", extraPanes: [[
                        "pane_id": "w1:p2", "workspace_id": "w1", "tab_id": "w1:t1",
                        "terminal_title_stripped": "◐ Fix tests",
                    ]]
                )],
                excluding: nil
            )
            XCTAssertEqual(entries.first?.tabs.first?.label, expected)
        }
    }

    func testTabDoesNotUseTitleFromAnotherWorkspace() throws {
        let endpoint = MachineEndpoint(profileID: "remote", session: "default")
        let machine = MachineEntry(endpoint: endpoint, label: "Remote", health: .online)
        let entries = InstanceWorkspace.entries(
            machines: [machine],
            snapshots: [endpoint: try snapshot(
                label: "Space", paneID: "w1:p1", tabLabel: "1",
                extraPanes: [[
                    "pane_id": "w2:p1", "workspace_id": "w2", "tab_id": "w1:t1",
                    "terminal_title": "Other space",
                ]]
            )],
            excluding: nil
        )
        XCTAssertEqual(entries.first?.tabs.first?.label, "shell")
    }

    private func snapshot(
        label: String,
        paneID: String,
        tabLabel: String = "Shell",
        cwd: String? = nil,
        agent: String? = nil,
        extraPanes: [[String: Any]] = []
    ) throws -> HerdrEndpointSnapshot {
        var pane: [String: Any] = [
            "pane_id": paneID,
            "workspace_id": "w1",
            "tab_id": "w1:t1",
        ]
        if let cwd { pane["cwd"] = cwd }
        if let agent { pane["agent"] = agent }
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
                "label": tabLabel,
                "agent_status": "idle",
            ]],
            "panes": [pane] + extraPanes,
        ]
        return try JSONDecoder().decode(
            HerdrEndpointSnapshot.self,
            from: JSONSerialization.data(withJSONObject: value)
        )
    }
}
