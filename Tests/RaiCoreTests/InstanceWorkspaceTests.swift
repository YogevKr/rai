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

    func testAdHocRemoteConnectionMatchesSavedWorkspaceByTarget() throws {
        let saved = MachineEndpoint(profileID: "saved", session: "default")
        let workspace = try XCTUnwrap(
            InstanceWorkspace.entries(
                machines: [MachineEntry(
                    endpoint: saved,
                    label: "sawmills-cloud",
                    health: .online,
                    target: "sawmills-cloud"
                )],
                snapshots: [saved: try snapshot(label: "Remote", paneID: "w1:p1")],
                excluding: nil
            ).first
        )
        let adHoc = MachineEntry(
            endpoint: MachineEndpoint(profileID: "adhoc:sawmills-cloud", session: "default"),
            label: "Current Herd",
            health: .online,
            target: "sawmills-cloud"
        )

        XCTAssertTrue(workspace.belongs(to: adHoc))
    }

    func testWorkspaceDoesNotMatchDifferentRemoteTargetOrSession() throws {
        let saved = MachineEndpoint(profileID: "saved", session: "default")
        let workspace = try XCTUnwrap(
            InstanceWorkspace.entries(
                machines: [MachineEntry(
                    endpoint: saved,
                    label: "sawmills-cloud",
                    health: .online,
                    target: "sawmills-cloud"
                )],
                snapshots: [saved: try snapshot(label: "Remote", paneID: "w1:p1")],
                excluding: nil
            ).first
        )

        XCTAssertFalse(workspace.belongs(to: MachineEntry(
            endpoint: MachineEndpoint(profileID: "other", session: "default"),
            label: "Other",
            health: .online,
            target: "other-host"
        )))
        XCTAssertFalse(workspace.belongs(to: MachineEntry(
            endpoint: MachineEndpoint(profileID: "other", session: "review"),
            label: "sawmills-cloud",
            health: .online,
            target: "sawmills-cloud"
        )))
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
        extraPanes: [[String: Any]] = [],
        agents: [[String: Any]] = []
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
            "agents": agents,
        ]
        return try JSONDecoder().decode(
            HerdrEndpointSnapshot.self,
            from: JSONSerialization.data(withJSONObject: value)
        )
    }

    func testRemoteTitlesFollowAgentRecordsWhenPanesContainNoTitles() throws {
        let endpoint = MachineEndpoint(profileID: "remote", session: "default")
        let machine = MachineEntry(endpoint: endpoint, label: "Remote", health: .online)
        for (title, expected) in [
            ("◐ First task", "First task"),
            ("⠇ 01a11315-8fc2-7dc2-9bda-8708743222dd", "codex"),
            ("◓ Updated task", "Updated task"),
        ] {
            let source = try snapshot(label: "Space", paneID: "w1:p1", tabLabel: "1", agents: [[
                "pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1",
                "agent": "codex", "terminal_title_stripped": title,
            ]])
            let entries = InstanceWorkspace.entries(machines: [machine], snapshots: [endpoint: source], excluding: nil)
            XCTAssertEqual(entries.first?.tabs.first?.label, expected)
        }
    }

    func testRemoteTitleRequiresMatchingWorkspaceTabAndPane() throws {
        let endpoint = MachineEndpoint(profileID: "remote", session: "default")
        let machine = MachineEntry(endpoint: endpoint, label: "Remote", health: .online)
        let agents: [[String: Any]] = [
            ["pane_id": "w1:p1", "workspace_id": "w2", "tab_id": "w1:t1", "terminal_title": "Wrong space"],
            ["pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t2", "terminal_title": "Wrong tab"],
            ["pane_id": "missing", "workspace_id": "w1", "tab_id": "w1:t1", "terminal_title": "Missing pane"],
        ]
        let source = try snapshot(label: "Space", paneID: "w1:p1", tabLabel: "1", agents: agents)
        let entries = InstanceWorkspace.entries(machines: [machine], snapshots: [endpoint: source], excluding: nil)
        XCTAssertEqual(entries.first?.tabs.first?.label, "shell")
    }

    func testRemoteCustomTabLabelWinsOverAgentTitle() throws {
        let endpoint = MachineEndpoint(profileID: "remote", session: "default")
        let machine = MachineEntry(endpoint: endpoint, label: "Remote", health: .online)
        let source = try snapshot(label: "Space", paneID: "w1:p1", tabLabel: "My tab", agents: [[
            "pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1",
            "agent": "codex", "terminal_title": "New title",
        ]])
        let entries = InstanceWorkspace.entries(machines: [machine], snapshots: [endpoint: source], excluding: nil)
        XCTAssertEqual(entries.first?.tabs.first?.label, "My tab")
    }

    func testReadOnlyTitleRefreshRequiresTheSamePaneSetAndEndpoint() throws {
        let first = MachineEndpoint(profileID: "one", session: "default")
        let second = MachineEndpoint(profileID: "two", session: "default")
        let machines = [MachineEntry(endpoint: first, label: "One", health: .online),
                        MachineEntry(endpoint: second, label: "Two", health: .online)]
        let native = try snapshot(label: "Space", paneID: "w1:p1", tabLabel: "1")
        for (paneID, expected) in [("w1:p1", "Updated task"), ("replacement", "shell")] {
            let value: [String: Any] = [
                "version": "0.9.3", "protocol": 22, "workspaces": [], "layouts": [],
                "tabs": [["tab_id": "w1:t1", "workspace_id": "w1", "number": 1, "label": "1",
                          "focused": false, "pane_count": 1, "agent_status": "working"]],
                "panes": [["pane_id": paneID, "terminal_id": "term1", "workspace_id": "w1", "tab_id": "w1:t1",
                           "focused": false, "cwd": "/repo", "revision": 1, "agent": "codex",
                           "agent_status": "working", "terminal_title_stripped": "Updated task"]],
            ]
            let titles = try JSONDecoder().decode(SessionSnapshot.self, from: JSONSerialization.data(withJSONObject: value))
            let entries = InstanceWorkspace.entries(machines: machines, snapshots: [first: native, second: native],
                                                     excluding: nil, titleSnapshots: [first: titles])
            XCTAssertEqual(entries[0].tabs[0].label, expected)
            XCTAssertEqual(entries[1].tabs[0].label, "shell")
            XCTAssertEqual(entries[0].tabs[0].panes.map(\.paneID), ["w1:p1"])
        }
    }
}
