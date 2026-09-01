import XCTest
@testable import RaiCore

/// `displayLabel(for:)` is the shared source of truth every platform's UI
/// must call to turn a tab into a title. SAW: iOS's MonitorView used to read
/// `tab.label` directly instead, so a tab herdr had only auto-numbered (label
/// "1", "2", …) rendered as the literal digit on the phone while the Mac,
/// which always went through this function, showed the real pane title.
final class SnapshotDisplayTests: XCTestCase {
    private func workspace(_ id: String, label: String = "rai") -> Workspace {
        Workspace(
            workspaceID: id,
            number: 1,
            label: label,
            focused: false,
            paneCount: 1,
            tabCount: 1,
            activeTabID: "",
            agentStatus: .idle,
            worktree: nil
        )
    }

    private func tab(
        _ id: String,
        workspaceID: String,
        number: Int = 1,
        label: String
    ) -> HerdrTab {
        HerdrTab(
            tabID: id,
            workspaceID: workspaceID,
            number: number,
            label: label,
            focused: false,
            paneCount: 1,
            agentStatus: .idle
        )
    }

    private func pane(
        _ id: String,
        tabID: String,
        workspaceID: String,
        agent: String? = nil,
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
            agentStatus: .idle,
            revision: 1,
            scroll: nil
        )
    }

    private func snapshot(tabs: [HerdrTab], panes: [Pane]) -> SessionSnapshot {
        SessionSnapshot(
            version: "0.7.4",
            protocol: 16,
            focusedWorkspaceID: nil,
            focusedTabID: nil,
            focusedPaneID: nil,
            workspaces: [workspace("ws-1")],
            tabs: tabs,
            panes: panes,
            agents: nil,
            layouts: []
        )
    }

    func testNumericTabLabelFallsBackToTerminalTitleNotTheDigits() {
        let snapshot = snapshot(
            tabs: [tab("t1", workspaceID: "ws-1", number: 3, label: "3")],
            panes: [pane("p1", tabID: "t1", workspaceID: "ws-1", agent: "claude", title: "Fix login bug")]
        )

        XCTAssertEqual(snapshot.displayLabel(for: snapshot.tabs[0]), "Fix login bug")
    }

    func testNumericTabLabelFallsBackToAgentWhenNoTerminalTitle() {
        let snapshot = snapshot(
            tabs: [tab("t1", workspaceID: "ws-1", number: 2, label: "2")],
            panes: [pane("p1", tabID: "t1", workspaceID: "ws-1", agent: "codex")]
        )

        XCTAssertEqual(snapshot.displayLabel(for: snapshot.tabs[0]), "codex")
    }

    func testNumericTabLabelFallsBackToShellWithNothingElse() {
        let snapshot = snapshot(
            tabs: [tab("t1", workspaceID: "ws-1", number: 1, label: "1")],
            panes: [pane("p1", tabID: "t1", workspaceID: "ws-1")]
        )

        XCTAssertEqual(snapshot.displayLabel(for: snapshot.tabs[0]), "shell")
    }

    func testCustomTabLabelIsUsedVerbatimEvenWithPaneTitlePresent() {
        let snapshot = snapshot(
            tabs: [tab("t1", workspaceID: "ws-1", label: "Review PR")],
            panes: [pane("p1", tabID: "t1", workspaceID: "ws-1", title: "some other title")]
        )

        XCTAssertEqual(snapshot.displayLabel(for: snapshot.tabs[0]), "Review PR")
    }

    func testWhitespaceOnlyLabelIsTreatedAsBlank() {
        let snapshot = snapshot(
            tabs: [tab("t1", workspaceID: "ws-1", label: "   ")],
            panes: [pane("p1", tabID: "t1", workspaceID: "ws-1", agent: "claude")]
        )

        XCTAssertEqual(snapshot.displayLabel(for: snapshot.tabs[0]), "claude")
    }

    func testHasUsefulLabelRejectsBlankAndNumericAcceptsText() {
        XCTAssertFalse(tab("t1", workspaceID: "ws-1", label: "").hasUsefulLabel)
        XCTAssertFalse(tab("t1", workspaceID: "ws-1", label: "   ").hasUsefulLabel)
        XCTAssertFalse(tab("t1", workspaceID: "ws-1", label: "42").hasUsefulLabel)
        XCTAssertTrue(tab("t1", workspaceID: "ws-1", label: "Review PR").hasUsefulLabel)
    }
}
