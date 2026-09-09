import Foundation
import XCTest
@testable import RaiCore

final class WorkspaceClosePreviewTests: XCTestCase {
    private func snapshot(protocolVersion: Int = 22, extraMember: Bool = false) -> SessionSnapshot {
        func workspace(_ id: String, key: String, linked: Bool) -> Workspace {
            Workspace(workspaceID: id, number: 1, label: id, focused: false,
                      paneCount: 1, tabCount: 1, activeTabID: "\(id):t1", agentStatus: .unknown,
                      worktree: WorkspaceWorktree(repoKey: key, repoName: "same-name", repoRoot: "/tmp/\(key)",
                                                  checkoutPath: "/tmp/\(id)", isLinkedWorktree: linked))
        }
        var workspaces = [workspace("w1", key: "repo-a", linked: false),
                          workspace("w2", key: "repo-b", linked: false),
                          workspace("w3", key: "repo-a", linked: true)]
        if extraMember { workspaces.append(workspace("w4", key: "repo-a", linked: true)) }
        return SessionSnapshot(version: "test", protocol: protocolVersion, focusedWorkspaceID: nil,
                               focusedTabID: nil, focusedPaneID: nil, workspaces: workspaces,
                               tabs: [], panes: [], agents: nil, layouts: [])
    }

    func testGroupPreviewUsesRepositoryIdentityAndIncludesNonadjacentMembers() throws {
        let snapshot = snapshot()
        let preview = try XCTUnwrap(WorkspaceClosePreview(snapshot: snapshot, workspaceID: "w1", closeGroup: true))
        XCTAssertEqual(preview.workspaceIDs, ["w1", "w3"])
        XCTAssertTrue(preview.message.contains("w1, w3"))
        XCTAssertNoThrow(try preview.validate(against: snapshot))
        let child = try XCTUnwrap(WorkspaceClosePreview(snapshot: snapshot, workspaceID: "w3", closeGroup: false))
        XCTAssertEqual(child.workspaceIDs, ["w3"])
        XCTAssertNoThrow(try child.validate(against: snapshot))
    }

    func testOrdinaryClosureCannotImplicitlyCloseAGroupOnEitherVersion() throws {
        for version in [20, 22] {
            let snapshot = snapshot(protocolVersion: version)
            let preview = try XCTUnwrap(WorkspaceClosePreview(snapshot: snapshot, workspaceID: "w1", closeGroup: false))
            XCTAssertThrowsError(try preview.validate(against: snapshot))
        }
    }

    func testNewGroupMembersRequireAnotherPreview() throws {
        let preview = try XCTUnwrap(WorkspaceClosePreview(snapshot: snapshot(), workspaceID: "w1", closeGroup: true))
        XCTAssertThrowsError(try preview.validate(against: snapshot(extraMember: true)))
    }

    func testCloseOrderClosesLinkedMembersBeforePrimary() throws {
        let preview = try XCTUnwrap(WorkspaceClosePreview(snapshot: snapshot(), workspaceID: "w1", closeGroup: true))
        XCTAssertEqual(try preview.closureOrder(), ["w3", "w1"])
    }

    func testConfirmationRejectsAnotherConnectionWithTheSameWorkspaceIDs() throws {
        let current = snapshot()
        let preview = try XCTUnwrap(WorkspaceClosePreview(snapshot: current, workspaceID: "w1", closeGroup: true, connectionID: "original"))
        XCTAssertNoThrow(try preview.validate(against: current, connectionID: "original"))
        XCTAssertThrowsError(try preview.validate(against: current, connectionID: "replacement"))
    }

    func testMultiplePrimariesRejectClosureBeforeAnyMutation() throws {
        let data = try JSONEncoder().encode(snapshot())
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
            .replacingOccurrences(of: "\"is_linked_worktree\":true", with: "\"is_linked_worktree\":false")
        let current = try JSONDecoder().decode(SessionSnapshot.self, from: Data(text.utf8))
        let preview = try XCTUnwrap(WorkspaceClosePreview(snapshot: current, workspaceID: "w1", closeGroup: true))
        XCTAssertThrowsError(try preview.closureOrder())
    }

    func testOlderServerCannotReceiveGroupClosure() throws {
        let snapshot = snapshot(protocolVersion: 20)
        let preview = try XCTUnwrap(WorkspaceClosePreview(snapshot: snapshot, workspaceID: "w1", closeGroup: true))
        XCTAssertThrowsError(try preview.validate(against: snapshot))
    }

    func testCapabilitiesKeepEndpointGenerationSeparateFromAPIProtocol() throws {
        let data = Data(#"{"version":"0.9.0","protocol":22,"capabilities":{"live_handoff":true,"endpoint_protocol_generation":1,"future_capability":true}}"#.utf8)
        let server = try JSONDecoder().decode(HerdrServerInfo.self, from: data)
        XCTAssertEqual(server.protocol, 22)
        XCTAssertEqual(server.capabilities?.endpointProtocolGeneration, 1)
        XCTAssertNil(server.capabilities?.healthCheck)
        XCTAssertTrue(BridgeHostCapabilities(operations: [BridgeCapability.workspaceGroupClose], server: server, connectionID: "test-generation").supportsWorkspaceGroupClose)
        XCTAssertFalse(BridgeHostCapabilities(operations: [], server: server).supportsWorkspaceGroupClose)
        let legacy = try JSONDecoder().decode(HerdrServerInfo.self, from: Data(#"{"version":"0.8.2","protocol":20}"#.utf8))
        XCTAssertNil(legacy.capabilities)
        XCTAssertFalse(BridgeHostCapabilities(operations: [BridgeCapability.workspaceGroupClose], server: legacy).supportsWorkspaceGroupClose)
        let capabilities = BridgeHostCapabilities(operations: [BridgeCapability.workspaceGroupClose, BridgeCapability.museAgent], server: server, connectionID: "test-generation")
        let message = BridgeMessage.snapshot(snapshot(), sessionName: "lab", capabilities: capabilities)
        let encoded = try JSONEncoder().encode(message)
        guard case .snapshot(_, let session, let decoded) = try JSONDecoder().decode(BridgeMessage.self, from: encoded) else {
            return XCTFail("Expected a snapshot")
        }
        XCTAssertEqual(session, "lab")
        XCTAssertEqual(decoded, capabilities)
        XCTAssertTrue(decoded?.supportsMuse == true)
    }
}
