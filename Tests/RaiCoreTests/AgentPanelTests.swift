import XCTest
@testable import RaiCore

final class AgentPanelTests: XCTestCase {
    private func workspace(
        _ id: String,
        number: Int = 1,
        label: String,
        tabCount: Int = 1,
        paneCount: Int = 1
    ) -> Workspace {
        Workspace(
            workspaceID: id,
            number: number,
            label: label,
            focused: false,
            paneCount: paneCount,
            tabCount: tabCount,
            activeTabID: "",
            agentStatus: .idle,
            worktree: nil
        )
    }

    private func tab(
        _ id: String,
        workspaceID: String,
        number: Int = 1,
        label: String,
        paneCount: Int = 1
    ) -> HerdrTab {
        HerdrTab(
            tabID: id,
            workspaceID: workspaceID,
            number: number,
            label: label,
            focused: false,
            paneCount: paneCount,
            agentStatus: .idle
        )
    }

    private func pane(
        _ id: String,
        tabID: String,
        workspaceID: String,
        agent: String? = "claude",
        status: AgentStatus = .idle,
        title: String? = nil
    ) -> Pane {
        Pane(
            paneID: id,
            terminalID: "term-\(id)",
            workspaceID: workspaceID,
            tabID: tabID,
            focused: false,
            cwd: "/repo",
            foregroundCWD: nil,
            agent: agent,
            agentSession: nil,
            terminalTitle: title,
            terminalTitleStripped: title,
            agentStatus: status,
            revision: 1,
            scroll: nil
        )
    }

    private func snapshot(
        workspaces: [Workspace],
        tabs: [HerdrTab],
        panes: [Pane],
        agents: [HerdrAgent]? = nil
    ) -> SessionSnapshot {
        SessionSnapshot(
            version: "0.7.4",
            protocol: 16,
            focusedWorkspaceID: nil,
            focusedTabID: nil,
            focusedPaneID: nil,
            workspaces: workspaces,
            tabs: tabs,
            panes: panes,
            agents: agents,
            layouts: []
        )
    }

    private func agent(
        _ id: String,
        tabID: String,
        workspaceID: String,
        label: String = "claude",
        status: AgentStatus = .idle,
        title: String? = nil
    ) -> HerdrAgent {
        HerdrAgent(
            terminalID: "term-\(id)",
            name: nil,
            agent: label,
            title: nil,
            terminalTitle: title,
            terminalTitleStripped: title,
            displayAgent: nil,
            agentStatus: status,
            agentSession: nil,
            workspaceID: workspaceID,
            tabID: tabID,
            paneID: id,
            focused: false,
            cwd: "/repo",
            foregroundCWD: nil,
            revision: 1
        )
    }

    /// blocked → done → working → idle, matching herdr's attention order.
    func testPrioritySortLeadsWithAgentsThatNeedYou() {
        let statuses: [(String, AgentStatus)] = [
            ("pane-idle", .idle),
            ("pane-working", .working),
            ("pane-blocked", .blocked),
            ("pane-done", .done),
            ("pane-unknown", .unknown),
        ]
        let entries = AgentPanel.entries(
            in: snapshot(
                workspaces: [workspace("ws-1", label: "rai", paneCount: 5)],
                tabs: [tab("tab-1", workspaceID: "ws-1", label: "1", paneCount: 5)],
                panes: statuses.map {
                    pane($0.0, tabID: "tab-1", workspaceID: "ws-1", status: $0.1)
                }
            ),
            sort: .priority
        )
        XCTAssertEqual(
            entries.map(\.paneID),
            ["pane-blocked", "pane-done", "pane-working", "pane-idle", "pane-unknown"]
        )
    }

    /// Equal-priority rows must not reshuffle between snapshots.
    func testPrioritySortKeepsHerdOrderWithinABand() {
        let panes = (1...4).map {
            pane("pane-\($0)", tabID: "tab-1", workspaceID: "ws-1", status: .working)
        }
        let entries = AgentPanel.entries(
            in: snapshot(
                workspaces: [workspace("ws-1", label: "rai", paneCount: 4)],
                tabs: [tab("tab-1", workspaceID: "ws-1", label: "1", paneCount: 4)],
                panes: panes
            ),
            sort: .priority
        )
        XCTAssertEqual(
            entries.map(\.paneID),
            ["pane-1", "pane-2", "pane-3", "pane-4"]
        )
    }

    func testGroupedSortKeepsSpaceThenTabThenPaneOrder() {
        let entries = AgentPanel.entries(
            in: snapshot(
                workspaces: [
                    workspace("ws-1", number: 1, label: "rai"),
                    workspace("ws-2", number: 2, label: "needle"),
                ],
                tabs: [
                    tab("tab-1", workspaceID: "ws-1", label: "1"),
                    tab("tab-2", workspaceID: "ws-2", label: "2"),
                ],
                panes: [
                    // Deliberately out of herd order: the tree drives the list.
                    pane("pane-2", tabID: "tab-2", workspaceID: "ws-2", status: .blocked),
                    pane("pane-1", tabID: "tab-1", workspaceID: "ws-1"),
                ]
            ),
            sort: .grouped
        )
        XCTAssertEqual(entries.map(\.paneID), ["pane-1", "pane-2"])
        XCTAssertEqual(entries.map(\.workspaceLabel), ["rai", "needle"])
    }

    /// The projection decides membership AND enriches the row it matches.
    func testAgentProjectionDecidesMembershipAndEnrichesTheRow() {
        let entries = AgentPanel.entries(
            in: snapshot(
                workspaces: [workspace("ws-1", label: "rai", paneCount: 2)],
                tabs: [tab("tab-1", workspaceID: "ws-1", label: "1", paneCount: 2)],
                panes: [
                    pane(
                        "pane-agent",
                        tabID: "tab-1",
                        workspaceID: "ws-1",
                        agent: "codex",
                        status: .idle
                    ),
                    pane("shell", tabID: "tab-1", workspaceID: "ws-1", agent: nil),
                ],
                agents: [
                    agent(
                        "pane-agent",
                        tabID: "tab-1",
                        workspaceID: "ws-1",
                        status: .blocked
                    ),
                ]
            ),
            sort: .grouped
        )
        // The plain shell is not an agent and does not belong in this panel.
        XCTAssertEqual(entries.map(\.paneID), ["pane-agent"])
        // The projection's agent and status win over the pane's stale copy.
        XCTAssertEqual(entries.first?.agentLabel, "claude")
        XCTAssertEqual(entries.first?.status, .blocked)
    }

    func testShellOnlyHerdListsNoAgents() {
        let entries = AgentPanel.entries(
            in: snapshot(
                workspaces: [workspace("ws-1", label: "rai")],
                tabs: [tab("tab-1", workspaceID: "ws-1", label: "1")],
                panes: [pane("pane-1", tabID: "tab-1", workspaceID: "ws-1", agent: nil)],
                agents: []
            ),
            sort: .grouped
        )
        XCTAssertTrue(entries.isEmpty)
    }

    /// A lone auto-named tab repeats nothing useful next to its space name.
    func testAutoNamedSoleTabContributesNoTabLabel() {
        let entries = AgentPanel.entries(
            in: snapshot(
                workspaces: [workspace("ws-1", label: "rai")],
                tabs: [tab("tab-1", workspaceID: "ws-1", label: "1")],
                panes: [pane("pane-1", tabID: "tab-1", workspaceID: "ws-1")]
            ),
            sort: .grouped
        )
        XCTAssertNil(entries.first?.tabLabel)
    }

    func testNamedTabAndMultiTabSpacesShowTheTabLabel() {
        let named = AgentPanel.entries(
            in: snapshot(
                workspaces: [workspace("ws-1", label: "rai")],
                tabs: [tab("tab-1", workspaceID: "ws-1", label: "Review PR")],
                panes: [pane("pane-1", tabID: "tab-1", workspaceID: "ws-1")]
            ),
            sort: .grouped
        )
        XCTAssertEqual(named.first?.tabLabel, "Review PR")

        let multi = AgentPanel.entries(
            in: snapshot(
                workspaces: [workspace("ws-1", label: "rai", tabCount: 2, paneCount: 2)],
                tabs: [
                    tab("tab-1", workspaceID: "ws-1", number: 1, label: "1"),
                    tab("tab-2", workspaceID: "ws-1", number: 2, label: "2"),
                ],
                panes: [
                    pane("pane-1", tabID: "tab-1", workspaceID: "ws-1", title: "build"),
                    pane("pane-2", tabID: "tab-2", workspaceID: "ws-1", title: "test"),
                ]
            ),
            sort: .grouped
        )
        // An auto-named tab in a multi-tab space falls back to the pane title.
        XCTAssertEqual(multi.map(\.tabLabel), ["build", "test"])
    }

    /// Without the server's agent projection, a pane's own detected agent is
    /// the membership test — and a blank one is no agent at all.
    func testPaneWithoutAnAgentIsNotListed() {
        let entries = AgentPanel.entries(
            in: snapshot(
                workspaces: [workspace("ws-1", label: "rai", paneCount: 2)],
                tabs: [tab("tab-1", workspaceID: "ws-1", label: "1", paneCount: 2)],
                panes: [
                    pane("pane-1", tabID: "tab-1", workspaceID: "ws-1", agent: "claude"),
                    pane("pane-2", tabID: "tab-1", workspaceID: "ws-1", agent: "  "),
                ]
            ),
            sort: .grouped
        )
        XCTAssertEqual(entries.map(\.paneID), ["pane-1"])
        XCTAssertEqual(entries.map(\.agentLabel), ["claude"])
    }

    func testUnlabelledSpaceFallsBackToItsNumber() {
        let entries = AgentPanel.entries(
            in: snapshot(
                workspaces: [workspace("ws-1", number: 3, label: "  ")],
                tabs: [tab("tab-1", workspaceID: "ws-1", label: "1")],
                panes: [pane("pane-1", tabID: "tab-1", workspaceID: "ws-1")]
            ),
            sort: .grouped
        )
        XCTAssertEqual(entries.first?.workspaceLabel, "Space 3")
    }

    func testSortToggleRoundTrips() {
        XCTAssertEqual(AgentPanelSort.priority.toggled, .grouped)
        XCTAssertEqual(AgentPanelSort.grouped.toggled, .priority)
        XCTAssertEqual(AgentPanelSort.priority.label, "priority")
    }
}
