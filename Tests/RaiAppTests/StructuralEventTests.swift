import XCTest
import RaiCore
import AppKit

@testable import RaiApp

/// High-rate events must NOT trigger an immediate snapshot refresh. Output
/// arrives as `pane.updated` on protocol 16. A new event subscription can also
/// replay a long focus history. Both streams use one trailing refresh instead.
@MainActor
final class StructuralEventTests: XCTestCase {
    func testOutputEventsAreNotStructural() {
        XCTAssertFalse(RaiModel.isStructuralEvent("pane.output_changed"))
        XCTAssertFalse(RaiModel.isStructuralEvent("pane.updated"))
    }

    func testReplayedFocusEventsAreNotStructural() {
        XCTAssertFalse(RaiModel.isStructuralEvent("pane.focused"))
        XCTAssertFalse(RaiModel.isStructuralEvent("workspace.focused"))
    }

    func testStructuralEventsStillRefresh() {
        for name in [
            "layout.updated", "pane.created", "pane.closed", "pane.moved",
            "pane.agent_status_changed", "tab.closed", "tab.moved",
            "workspace.moved", "workspace.renamed", "workspace.reordered",
        ] {
            XCTAssertTrue(RaiModel.isStructuralEvent(name), name)
        }
    }

    func testExternalFocusRefreshFollowsTheServerPane() throws {
        let previous = try snapshot(focusedWorkspace: "w1", focusedTab: "t1", focusedPane: "p1")
        let next = try snapshot(focusedWorkspace: "w2", focusedTab: "t2", focusedPane: "p2")

        XCTAssertEqual(
            RaiModel.selectionAfterSnapshot(
                previous: previous, next: next, current: "p1", keepSelection: true
            ),
            "p2"
        )
    }

    func testUnchangedServerFocusKeepsTheLocalPane() throws {
        let previous = try snapshot(focusedWorkspace: "w1", focusedTab: "t1", focusedPane: "p1")
        let next = try snapshot(focusedWorkspace: "w1", focusedTab: "t1", focusedPane: "p1")

        XCTAssertEqual(
            RaiModel.selectionAfterSnapshot(
                previous: previous, next: next, current: "p2", keepSelection: true
            ),
            "p2"
        )
    }

    func testLegacyFocusRefreshFollowsThePaneFlag() throws {
        let previous = try snapshot(
            focusedWorkspace: "w1", focusedTab: "t1", focusedPane: "p1",
            includeTopLevelFocus: false
        )
        let next = try snapshot(
            focusedWorkspace: "w2", focusedTab: "t2", focusedPane: "p2",
            includeTopLevelFocus: false
        )

        XCTAssertEqual(
            RaiModel.selectionAfterSnapshot(
                previous: previous, next: next, current: "p1", keepSelection: true
            ),
            "p2"
        )
    }

    func testExternalFocusDoesNotReplaceANewerLocalSelection() throws {
        let previous = try snapshot(focusedWorkspace: "w1", focusedTab: "t1", focusedPane: "p1")
        let next = try snapshot(focusedWorkspace: "w2", focusedTab: "t2", focusedPane: "p2")

        for keepSelection in [true, false] {
            XCTAssertEqual(
                RaiModel.selectionAfterSnapshot(
                    previous: previous, next: next, current: "p1", keepSelection: keepSelection,
                    protectLocalSelection: true
                ),
                "p1"
            )
        }
    }

    func testOverlappingServerRefreshesFollowTheLaterFocus() throws {
        _ = NSApplication.shared
        let model = RaiModel(
            client: HerdrClient(socketPath: "/nonexistent/rai-focus-tests.sock"),
            userDefaults: try XCTUnwrap(UserDefaults(suiteName: "rai-focus-tests-\(UUID())"))
        )
        let first = try snapshot(focusedWorkspace: "w1", focusedTab: "t1", focusedPane: "p1")
        let second = try snapshot(focusedWorkspace: "w2", focusedTab: "t2", focusedPane: "p2")
        model.selectedPaneID = "p1"
        let requestedRevision = model.selectionRevision

        model.applySnapshotSelection(
            previous: first, next: second, keepSelection: true,
            requestedSelectionRevision: requestedRevision
        )
        XCTAssertEqual(model.selectedPaneID, "p2")
        model.applySnapshotSelection(
            previous: second, next: first, keepSelection: true,
            requestedSelectionRevision: requestedRevision
        )
        XCTAssertEqual(model.selectedPaneID, "p1")

        model.selectedPaneID = "p2"
        model.applySnapshotSelection(
            previous: second, next: first, keepSelection: false,
            requestedSelectionRevision: requestedRevision
        )
        XCTAssertEqual(model.selectedPaneID, "p2")
    }

    private func snapshot(
        focusedWorkspace: String,
        focusedTab: String,
        focusedPane: String,
        includeTopLevelFocus: Bool = true
    ) throws -> SessionSnapshot {
        let focusFields = includeTopLevelFocus
            ? "\"focused_workspace_id\":\"\(focusedWorkspace)\",\"focused_tab_id\":\"\(focusedTab)\",\"focused_pane_id\":\"\(focusedPane)\","
            : "\"focused_workspace_id\":null,\"focused_tab_id\":null,\"focused_pane_id\":null,"
        return try JSONDecoder().decode(SessionSnapshot.self, from: Data("""
        {
          "version":"test","protocol":1,\(focusFields)
          "workspaces":[],"tabs":[],
          "panes":[
            {"pane_id":"p1","terminal_id":"term-1","workspace_id":"w1","tab_id":"t1",
             "focused":\(focusedPane == "p1"),"cwd":"/tmp","agent":null,"agent_status":"idle","revision":1},
            {"pane_id":"p2","terminal_id":"term-2","workspace_id":"w2","tab_id":"t2",
             "focused":\(focusedPane == "p2"),"cwd":"/tmp","agent":null,"agent_status":"idle","revision":1}
          ],"layouts":[]
        }
        """.utf8))
    }
}
