import XCTest
@testable import RaiCore

final class EndpointWorktreeTests: XCTestCase {
    private func snapshot(boot: String = "boot", linked: Bool = true, focus: String = "w1") throws -> HerdrEndpointSnapshot {
        let object: [String: Any] = ["boot_id": boot, "revision": 1, "focused_workspace_id": focus,
            "workspaces": [["workspace_id": "w1", "worktree": ["is_linked_worktree": linked]], ["workspace_id": "w2"]]]
        return try JSONDecoder().decode(HerdrEndpointSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testCreateAndOpenRequestOwningViewNavigationWithExplicitTarget() throws {
        let operations: [EndpointWorktreeOperation] = [
            .create(workspaceID: "w1", branch: "feature", base: "main", path: "/tmp/lab/tree", label: "Test", trust: true),
            .open(workspaceID: "w1", path: "/tmp/lab/tree", trust: false),
        ]
        for operation in operations {
            XCTAssertEqual(operation.rpc.params["focus"], .bool(true))
            XCTAssertEqual(operation.rpc.params["workspace_id"], .string("w1"))
            try EndpointWorktreeRequest(bootID: "boot", operation: operation).validate(in: snapshot(focus: "w2"))
        }
    }

    func testTrustAppliesOnlyToTheExplicitRequest() {
        let trusted = EndpointWorktreeOperation.list(workspaceID: "w1", trust: true)
        let next = EndpointWorktreeOperation.open(workspaceID: "w1", path: "/tmp/lab/tree", trust: false)
        XCTAssertEqual(trusted.rpc.params["trust_repository"], .bool(true))
        XCTAssertEqual(next.rpc.params["trust_repository"], .bool(false))
        XCTAssertEqual(Set(trusted.rpc.params.keys), ["workspace_id", "trust_repository"])
    }

    func testRemovedWorkspaceAndRestartRejectStaleRequests() throws {
        let request = EndpointWorktreeRequest(bootID: "boot", operation: .list(workspaceID: "w1", trust: false))
        XCTAssertThrowsError(try request.validate(in: snapshot(boot: "restarted")))
        let missing = EndpointWorktreeRequest(bootID: "boot", operation: .list(workspaceID: "w9", trust: false))
        XCTAssertThrowsError(try missing.validate(in: snapshot()))
    }

    func testRemovalRejectsMainCheckoutAndPreservesExplicitForce() throws {
        let request = EndpointWorktreeRequest(bootID: "boot", operation: .remove(workspaceID: "w1", force: false, trust: false))
        try request.validate(in: snapshot())
        XCTAssertEqual(request.operation.rpc.params["force"], .bool(false))
        XCTAssertThrowsError(try request.validate(in: snapshot(linked: false)))
        XCTAssertEqual(EndpointWorktreeOperation.remove(workspaceID: "w1", force: true, trust: true).rpc.params["force"], .bool(true))
    }

    func testInvalidPathsBranchesAndControlCharactersAreRejected() throws {
        let operations: [EndpointWorktreeOperation] = [
            .create(workspaceID: "w1", branch: " ", base: "", path: "", label: "", trust: false),
            .create(workspaceID: "w1", branch: "feature", base: "", path: "relative", label: "", trust: false),
            .create(workspaceID: "w1", branch: "feature\nmain", base: "", path: "", label: "", trust: false),
            .open(workspaceID: "w1", path: "../tree", trust: false),
        ]
        for operation in operations { XCTAssertThrowsError(try EndpointWorktreeRequest(bootID: "boot", operation: operation).validate(in: snapshot())) }
    }

    func testListResultAndBridgeRoundTripRetainRequestIdentity() throws {
        let request = EndpointWorktreeRequest(bootID: "boot", operation: .list(workspaceID: "w1", trust: false))
        let result: JSONValue = .object(["type": .string("worktree_list"), "worktrees": .array([
            .object(["path": .string("/tmp/lab/tree"), "branch": .string("feature"), "label": .string("Feature"),
                "is_bare": .bool(false), "is_detached": .bool(false), "is_prunable": .bool(false),
                "is_linked_worktree": .bool(true), "open_workspace_id": .string("w3")])])])
        let response = try EndpointWorktreeResult(request: request, result: result)
        XCTAssertEqual(response.worktrees.first?.openWorkspaceID, "w3")
        XCTAssertEqual(response.request.id, request.id)
        let operation = EndpointBridgeOperation.worktree(request)
        XCTAssertEqual(try JSONDecoder().decode(EndpointBridgeOperation.self, from: JSONEncoder().encode(operation)), operation)
        let state = EndpointBridgeState(identity: EndpointViewIdentity(connectionID: "host"), sequence: 3,
            snapshot: try snapshot(), surface: nil, methods: ["worktree.list"], busy: false, error: nil, worktreeResult: response)
        XCTAssertEqual(try JSONDecoder().decode(EndpointBridgeState.self, from: JSONEncoder().encode(state)), state)
        XCTAssertThrowsError(try EndpointWorktreeResult(request: request, result: .object(["type": .string("wrong")])))
    }

    func testSuccessfulWorktreeResultProvidesOnlyItsReturnedPaneForNavigation() throws {
        let cases: [(EndpointWorktreeOperation, String)] = [
            (.create(workspaceID: "w1", branch: "feature", base: "main", path: "", label: "", trust: false), "worktree_created"),
            (.open(workspaceID: "w1", path: "/tmp/tree", trust: false), "worktree_opened")]
        for (operation, type) in cases {
            let request = EndpointWorktreeRequest(bootID: "boot", operation: operation)
            let value: JSONValue = .object(["type": .string(type),
                "workspace": .object(["workspace_id": .string("w9")]),
                "root_pane": .object(["pane_id": .string("w9:p2"), "workspace_id": .string("w9")])])
            let result = try EndpointWorktreeResult(request: request, result: value)
            XCTAssertEqual(result.navigationPaneID, "w9:p2")
            XCTAssertEqual(try JSONDecoder().decode(EndpointWorktreeResult.self, from: JSONEncoder().encode(result)), result)
            XCTAssertThrowsError(try EndpointWorktreeResult(request: request, result: .object(["type": .string(type)])))
        }
    }
}
