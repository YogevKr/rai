import RaiCore
import XCTest
@testable import rai

@MainActor
final class EndpointWorktreeBridgeTests: XCTestCase {
    private func ready(_ model: EndpointPhoneModel, methods: [String] = ["worktree.list"], sequence: UInt64 = 1,
                       result: EndpointWorktreeResult? = nil) throws -> EndpointBridgeState {
        let snapshot = try JSONDecoder().decode(HerdrEndpointSnapshot.self,
            from: Data(#"{"boot_id":"boot","revision":1,"workspaces":[{"workspace_id":"w1"}]}"#.utf8))
        return EndpointBridgeState(identity: try XCTUnwrap(model.identity), sequence: sequence,
            snapshot: snapshot, surface: nil, methods: methods, busy: false, error: nil, worktreeResult: result)
    }

    func testConfirmedRequestRetainsTargetAndTrust() async throws {
        let model = EndpointPhoneModel()
        var sent: [EndpointBridgeRequest] = []
        model.open(connectionID: "host") { sent.append($0) }
        model.receive(try ready(model))
        let request = EndpointWorktreeRequest(bootID: "boot", operation: .list(workspaceID: "w1", trust: true))
        XCTAssertTrue(model.performWorktree(request))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(sent.last?.operation, .worktree(request))
        XCTAssertEqual(sent.last?.bootID, "boot")
        XCTAssertTrue(model.busy)
        let result = EndpointWorktreeResult(request: request, error: "Repository trust denied")
        model.receive(try ready(model, sequence: 2, result: result))
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.error, "A worktree failure must not break terminal input.")
        XCTAssertEqual(model.state?.worktreeResult, result)
        model.disconnect()
    }

    func testStaleUnsupportedAndClosedRequestsDoNotSend() throws {
        let model = EndpointPhoneModel()
        model.open(connectionID: "host") { _ in }
        model.receive(try ready(model, methods: []))
        let request = EndpointWorktreeRequest(bootID: "boot", operation: .list(workspaceID: "w1", trust: false))
        XCTAssertFalse(model.performWorktree(request))
        model.receive(try ready(model))
        let stale = EndpointWorktreeRequest(bootID: "old", operation: request.operation)
        XCTAssertFalse(model.performWorktree(stale))
        model.disconnect()
        XCTAssertFalse(model.performWorktree(request))
    }
}
