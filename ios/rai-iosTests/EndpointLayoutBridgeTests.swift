import RaiCore
import XCTest
@testable import rai

@MainActor
final class EndpointLayoutBridgeTests: XCTestCase {
    private func ready(_ model: EndpointPhoneModel, methods: [String] = ["pane.resize"], sequence: UInt64 = 1,
                       result: EndpointLayoutResult? = nil) throws -> EndpointBridgeState {
        let snapshot = try JSONDecoder().decode(HerdrEndpointSnapshot.self, from: Data(#"{"boot_id":"boot","revision":1,"focused_workspace_id":"w2","workspaces":[{"workspace_id":"w1"},{"workspace_id":"w2"}],"tabs":[{"tab_id":"w1:t1","workspace_id":"w1"}],"panes":[{"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1"}]}"#.utf8))
        var state = EndpointBridgeState(identity: try XCTUnwrap(model.identity), sequence: sequence,
            snapshot: snapshot, surface: nil, methods: methods, busy: false, error: nil)
        state.layoutResult = result
        return state
    }

    func testResizeUsesCapturedPaneAndReturnsRecoverableFailure() async throws {
        let model = EndpointPhoneModel()
        var sent: [EndpointBridgeRequest] = []
        model.open(connectionID: "host") { sent.append($0) }
        let state = try ready(model)
        model.receive(state)
        let request = try EndpointLayoutRequest(snapshot: XCTUnwrap(state.snapshot), owningViewID: state.identity.viewID,
            action: .resize(paneID: "w1:p1", direction: .right))
        XCTAssertTrue(model.performLayout(request))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(sent.last?.operation, .layout(request))
        XCTAssertEqual(sent.last?.identity.viewID, request.owningViewID)
        XCTAssertTrue(model.busy)
        let result = EndpointLayoutResult(requestID: request.id, message: "Split boundary unchanged", failed: true)
        model.receive(try ready(model, sequence: 2, result: result))
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.state?.layoutResult, result)
        model.disconnect()
    }

    func testOldViewCannotSendAndPublicPaneMoveRemainsAvailable() throws {
        let model = EndpointPhoneModel()
        model.open(connectionID: "host") { _ in }
        let state = try ready(model, methods: [])
        model.receive(state)
        let snapshot = try XCTUnwrap(state.snapshot)
        let resize = try EndpointLayoutRequest(snapshot: snapshot, owningViewID: state.identity.viewID,
            action: .resize(paneID: "w1:p1", direction: .left))
        XCTAssertFalse(model.performLayout(resize))
        let stale = try EndpointLayoutRequest(snapshot: snapshot, owningViewID: UUID(),
            action: .movePane(paneID: "w1:p1", destination: .newWorkspace(label: nil, tabLabel: nil)))
        XCTAssertFalse(model.performLayout(stale))
        let move = try EndpointLayoutRequest(snapshot: snapshot, owningViewID: state.identity.viewID,
            action: stale.action)
        XCTAssertTrue(model.performLayout(move))
        model.disconnect()
        XCTAssertFalse(model.performLayout(move))
    }
}
