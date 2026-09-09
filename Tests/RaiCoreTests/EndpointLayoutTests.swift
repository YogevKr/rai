import XCTest
@testable import RaiCore

final class EndpointLayoutTests: XCTestCase {
    private let viewID = UUID()

    private func snapshot(boot: String = "boot", focus: String = "w1", reordered: Bool = false,
                          movedPane: Bool = false, extraGroup: Bool = false, closed: [String] = []) throws -> HerdrEndpointSnapshot {
        func workspace(_ id: String, linked: Bool, key: String) -> [String: Any] {
            ["workspace_id": id, "number": 1, "label": id, "focused": id == focus,
             "pane_count": 1, "tab_count": 1, "active_tab_id": id + ":t1", "agent_status": "idle",
             "worktree": ["repo_key": key, "repo_name": key, "checkout_path": "/tmp/" + id, "is_linked_worktree": linked]]
        }
        var workspaces = [workspace("w1", linked: false, key: "main"), workspace("w2", linked: true, key: "main"),
                          workspace("w3", linked: false, key: "other")]
        if extraGroup { workspaces.append(workspace("w4", linked: true, key: "main")) }
        workspaces.removeAll { closed.contains($0["workspace_id"] as! String) }
        var tabs = [["tab_id": "w1:t1", "workspace_id": "w1"], ["tab_id": "w1:t2", "workspace_id": "w1"],
                    ["tab_id": "w2:t1", "workspace_id": "w2"]]
        if reordered { workspaces.swapAt(0, 1); tabs.swapAt(0, 1) }
        let value: [String: Any] = ["boot_id": boot, "revision": focus == "w1" ? 1 : 999,
            "focused_workspace_id": focus, "focused_tab_id": focus + ":t1", "focused_pane_id": focus + ":p1",
            "workspaces": workspaces, "tabs": tabs, "panes": [
                ["pane_id": "w1:p1", "workspace_id": "w1", "tab_id": movedPane ? "w1:t2" : "w1:t1"],
                ["pane_id": "w1:p2", "workspace_id": "w1", "tab_id": "w1:t2"],
                ["pane_id": "w2:p1", "workspace_id": "w2", "tab_id": "w2:t1"]]]
        return try JSONDecoder().decode(HerdrEndpointSnapshot.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private func request(_ action: EndpointLayoutAction) throws -> EndpointLayoutRequest {
        try EndpointLayoutRequest(snapshot: snapshot(), owningViewID: viewID, action: action)
    }

    func testRealEndpointWorkspaceShapeConvertsForClosure() throws {
        let snapshot = try JSONDecoder().decode(HerdrEndpointSnapshot.self, from: Data(#"{"boot_id":"boot","revision":1,"workspaces":[{"workspace_id":"w1","number":1,"label":"Repo","focused":true,"active_tab_id":"w1:t1","agent_status":"idle","worktree":{"key":"repo-key","label":"repo","is_linked_worktree":false}}],"tabs":[{"workspace_id":"w1","tab_id":"w1:t1"}],"panes":[{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1"}]}"#.utf8))
        let workspaces = try EndpointLayoutRequest.workspaces(snapshot)
        XCTAssertEqual(workspaces.first?.paneCount, 1)
        XCTAssertEqual(workspaces.first?.tabCount, 1)
        XCTAssertEqual(workspaces.first?.worktree?.repoKey, "repo-key")
        XCTAssertEqual(workspaces.first?.worktree?.checkoutPath, "")
        let preview = try XCTUnwrap(WorkspaceClosePreview(workspaces: workspaces, workspaceID: "w1", closeGroup: false, connectionID: "boot"))
        _ = try EndpointLayoutRequest(snapshot: snapshot, owningViewID: viewID, action: .closeWorkspace(preview))
    }

    func testResizeRetainsCapturedPaneAcrossFocusAndOutputChanges() throws {
        let request = try request(.resize(paneID: "w1:p1", direction: .left))
        try request.validate(in: snapshot(focus: "w2"))
        XCTAssertEqual(request.rpc.params, ["pane_id": .string("w1:p1"), "direction": .string("left"), "amount": .number(0.05)])
        XCTAssertThrowsError(try request.validate(in: snapshot(boot: "restarted")))
        XCTAssertThrowsError(try request.validate(in: snapshot(movedPane: true)))
    }

    func testReorderUsesOriginalInsertionBoundariesAndRejectsChangedOrder() throws {
        let tab = try request(.moveTab(tabID: "w1:t1", beforeTabID: nil))
        XCTAssertEqual(tab.rpc.params["insert_index"], .number(2))
        try tab.validate(in: snapshot(focus: "w2"))
        XCTAssertThrowsError(try tab.validate(in: snapshot(reordered: true)))
        XCTAssertThrowsError(try request(.moveTab(tabID: "w1:t1", beforeTabID: "w2:t1")))
        let workspace = try request(.moveWorkspace(workspaceID: "w3", beforeWorkspaceID: "w1"))
        XCTAssertEqual(workspace.rpc.params["insert_index"], .number(0))
        XCTAssertThrowsError(try workspace.validate(in: snapshot(reordered: true)))
        XCTAssertThrowsError(try request(.moveWorkspace(workspaceID: "w1", beforeWorkspaceID: "w1")))
    }

    func testMoveValidatesBothParentsAndNeverChangesPublicFocus() throws {
        let request = try request(.movePane(paneID: "w1:p1",
            destination: .tab(tabID: "w2:t1", split: .right, targetPaneID: "w2:p1")))
        try request.validate(in: snapshot(focus: "w2"))
        XCTAssertEqual(request.destinationWorkspaceID, "w2")
        XCTAssertEqual(request.rpc.params["focus"], .bool(false))
        XCTAssertThrowsError(try self.request(.movePane(paneID: "w1:p1",
            destination: .tab(tabID: "w2:t1", split: .right, targetPaneID: "w1:p2"))))
        XCTAssertThrowsError(try self.request(.movePane(paneID: "w1:p1",
            destination: .tab(tabID: "w1:t1", split: .right, targetPaneID: "w1:p1"))))
        XCTAssertThrowsError(try self.request(.movePane(paneID: "w1:p1", destination: .newTab(workspaceID: nil, label: nil))))
    }

    func testCloseGroupReviewsExactMembersAndClosesLinkedFirst() throws {
        let snapshot = try snapshot()
        let preview = try XCTUnwrap(WorkspaceClosePreview(workspaces: EndpointLayoutRequest.workspaces(snapshot),
            workspaceID: "w1", closeGroup: true, connectionID: "boot"))
        let request = try request(.closeWorkspace(preview))
        XCTAssertEqual(try preview.closureOrder(), ["w2", "w1"])
        XCTAssertEqual(request.rpc.params["close_group"], .bool(false))
        XCTAssertThrowsError(try request.validate(in: self.snapshot(extraGroup: true)))
        try request.validateClosureProgress(in: self.snapshot(closed: ["w2"]), closed: ["w2"])
        XCTAssertThrowsError(try request.validateClosureProgress(in: self.snapshot(extraGroup: true, closed: ["w2"]), closed: ["w2"]))
        XCTAssertFalse(preview.workspaceIDs.contains("w3"))
    }

    func testSinglePrimaryCloseRejectsHiddenGroupAndLinkedClosePreservesPrimary() throws {
        let workspaces = try EndpointLayoutRequest.workspaces(snapshot())
        let primary = try XCTUnwrap(WorkspaceClosePreview(workspaces: workspaces, workspaceID: "w1", closeGroup: false, connectionID: "boot"))
        XCTAssertThrowsError(try request(.closeWorkspace(primary)))
        let linked = try XCTUnwrap(WorkspaceClosePreview(workspaces: workspaces, workspaceID: "w2", closeGroup: false, connectionID: "boot"))
        XCTAssertEqual(try request(.closeWorkspace(linked)).workspaceID, "w2")
        XCTAssertEqual(try linked.closureOrder(), ["w2"])
    }

    func testBridgeRoundTripPreservesViewAndMoveResultUsesReturnedIdentity() throws {
        let request = try request(.movePane(paneID: "w1:p1", destination: .newWorkspace(label: nil, tabLabel: nil)))
        let operation = EndpointBridgeOperation.layout(request)
        XCTAssertEqual(try JSONDecoder().decode(EndpointBridgeOperation.self, from: JSONEncoder().encode(operation)), operation)
        XCTAssertEqual(request.owningViewID, viewID)
        let value: JSONValue = .object(["type": .string("pane_move"), "move_result": .object([
            "changed": .bool(true), "previous_pane_id": .string("w1:p1"),
            "previous_workspace_id": .string("w1"), "previous_tab_id": .string("w1:t1"),
            "pane": .object(["pane_id": .string("w9:p7"), "workspace_id": .string("w9"), "tab_id": .string("w9:t1")])])])
        XCTAssertEqual(try EndpointLayoutResult.movedPane(in: value, request: request), "w9:p7")
        XCTAssertNil(try EndpointLayoutResult.movedPane(in: .object(["type": .string("pane_move"),
            "move_result": .object(["changed": .bool(false)])]), request: request))
        XCTAssertThrowsError(try EndpointLayoutResult.movedPane(in: .object(["type": .string("pane_move"),
            "move_result": .object(["changed": .bool(true)])]), request: request))
    }

    func testResizeResultDistinguishesBoundariesAndRejectsWrongPane() throws {
        let request = try request(.resize(paneID: "w1:p1", direction: .left))
        for changed in [false, true] {
            let result: JSONValue = .object(["type": .string("pane_resize"), "resize": .object([
                "pane_id": .string("w1:p1"), "changed": .bool(changed)])])
            XCTAssertEqual(try EndpointLayoutResult.changed(in: result, request: request), changed)
        }
        XCTAssertThrowsError(try EndpointLayoutResult.changed(in: .object(["type": .string("pane_resize"),
            "resize": .object(["pane_id": .string("w2:p1"), "changed": .bool(true)])]), request: request))
    }

    func testReorderResultChecksServerOrderAndDetectsNoOp() throws {
        let request = try request(.moveTab(tabID: "w1:t1", beforeTabID: nil))
        let result: JSONValue = .object(["type": .string("tab_list"), "tabs": .array([
            .object(["tab_id": .string("w1:t2")]), .object(["tab_id": .string("w1:t1")])])])
        XCTAssertTrue(try EndpointLayoutResult.changed(in: result, request: request))
        let noOp = try self.request(.moveTab(tabID: "w1:t2", beforeTabID: nil))
        XCTAssertThrowsError(try EndpointLayoutResult.changed(in: result, request: noOp))
        let unchanged: JSONValue = .object(["type": .string("tab_list"), "tabs": .array([
            .object(["tab_id": .string("w1:t1")]), .object(["tab_id": .string("w1:t2")])])])
        XCTAssertFalse(try EndpointLayoutResult.changed(in: unchanged, request: noOp))
    }
}
