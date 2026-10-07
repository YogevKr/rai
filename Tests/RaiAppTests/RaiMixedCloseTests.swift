import AppKit
import RaiCore
import XCTest
@testable import RaiApp

@MainActor
final class RaiMixedCloseTests: XCTestCase {
    private func fixture() throws -> (RaiModel, RaiMixedViewModel, InstanceWorkspace, HerdrEndpointSnapshot) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaultsName = "rai-mixed-close-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.removePersistentDomain(forName: defaultsName)
        }
        let primary = RaiModel(client: HerdrClient(socketPath: "/nonexistent/rai-close-tests.sock"),
                               userDefaults: defaults)
        let model = RaiMixedViewModel(store: RaiCompositionStore(fileURL: root.appendingPathComponent("view.json")))
        let snapshot = try JSONDecoder().decode(HerdrEndpointSnapshot.self, from: Data("""
        {"boot_id":"boot","revision":1,
         "workspaces":[{"workspace_id":"w1","label":"Cloud","active_tab_id":"t1"}],
         "tabs":[{"workspace_id":"w1","tab_id":"t1"},{"workspace_id":"w1","tab_id":"t2"}],
         "panes":[{"workspace_id":"w1","tab_id":"t1","pane_id":"p1"},
                  {"workspace_id":"w1","tab_id":"t2","pane_id":"p2"}]}
        """.utf8))
        let endpoint = MachineEndpoint(profileID: "cloud", session: "default")
        let workspace = try XCTUnwrap(InstanceWorkspace.entries(
            machines: [MachineEntry(endpoint: endpoint, label: "Cloud", connectionID: "connection", health: .online)],
            snapshots: [endpoint: snapshot], excluding: nil).first)
        return (primary, model, workspace, snapshot)
    }

    func testCloseOnlyVisibleTabClosesSourceTabAndPreservesHiddenSibling() async throws {
        let (primary, model, workspace, snapshot) = try fixture()
        XCTAssertTrue(model.removeSourceTabs(from: workspace, tabID: "t2"))
        let visible = try XCTUnwrap(workspace.excludingDismissedTabs(model.composition.dismissedTabs))
        XCTAssertEqual(visible.tabs.map(\.id), ["t1"])
        var requests: [InstanceCloseRequest] = []
        let controller = RaiMixedController(primaryModel: primary, model: model, machines: MachineDirectory(),
            closeSource: { requests.append($0) })
        let task = try XCTUnwrap(controller.closeSourceTab(in: visible, tabID: "t1"))
        await task.value
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.method, "tab.close")
        XCTAssertEqual(request.params, ["tab_id": .string("t1")])
        XCTAssertEqual(request.workspace.id.endpoint, workspace.id.endpoint)
        XCTAssertEqual(request.connectionID, "connection")
        XCTAssertNoThrow(try request.validate(snapshot), "Hidden source siblings must not prevent tab closure")
        XCTAssertEqual(model.composition.dismissedTabs.map(\.tabID), ["t2"], "Closure must not create a dismissal")
        XCTAssertNil(primary.sessionAlert)
    }

    func testDuplicateCloseWaitsForCapturedRequestAndDoesNotChangeNewSelection() async throws {
        let (primary, model, workspace, _) = try fixture()
        var requests: [InstanceCloseRequest] = []
        var resume: CheckedContinuation<Void, Never>?
        let entered = expectation(description: "Close started")
        let controller = RaiMixedController(primaryModel: primary, model: model, machines: MachineDirectory(),
            closeSource: { request in
                requests.append(request)
                await withCheckedContinuation { resume = $0; entered.fulfill() }
            })
        let task = try XCTUnwrap(controller.closeSourceTab(in: workspace, tabID: "t1"))
        XCTAssertNil(controller.closeSourceTab(in: workspace, tabID: "t1"))
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertNil(controller.closeSourceTab(in: workspace, tabID: "t2"))
        let newerSelection = UUID()
        controller.selectedTabID = newerSelection
        resume?.resume()
        await task.value
        XCTAssertEqual(requests.map(\.tabID), ["t1"])
        XCTAssertEqual(controller.selectedTabID, newerSelection)
        XCTAssertTrue(controller.closingWorkspaces.isEmpty)
    }

    func testFailedCloseLeavesTabVisibleAndAllowsRetry() async throws {
        let (primary, model, workspace, _) = try fixture()
        var attempts = 0
        let controller = RaiMixedController(primaryModel: primary, model: model, machines: MachineDirectory(),
            closeSource: { _ in attempts += 1; throw HerdrEndpointError.staleIdentity })
        let before = model.composition
        let task = try XCTUnwrap(controller.closeSourceTab(in: workspace, tabID: "t1"))
        await task.value
        XCTAssertNotNil(primary.sessionAlert)
        XCTAssertEqual(model.composition, before)
        XCTAssertEqual(workspace.excludingDismissedTabs(model.composition.dismissedTabs)?.tabs.count, 2)
        let retry = try XCTUnwrap(controller.closeSourceTab(in: workspace, tabID: "t1"))
        await retry.value
        XCTAssertEqual(attempts, 2)
    }

    func testUnknownTabNeverSendsClose() throws {
        let (primary, model, workspace, _) = try fixture()
        let controller = RaiMixedController(primaryModel: primary, model: model, machines: MachineDirectory(),
            closeSource: { _ in XCTFail("Invalid tab must not reach the transport") })
        XCTAssertNil(controller.closeSourceTab(in: workspace, tabID: "missing"))
        XCTAssertNotNil(primary.sessionAlert)
        XCTAssertTrue(controller.closingWorkspaces.isEmpty)
    }
}
