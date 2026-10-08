import AppKit
import RaiCore
import XCTest
@testable import RaiApp

@MainActor
final class MachineNavigationTests: XCTestCase {
    private let remote = MachineEntry(endpoint: .init(profileID: "cloud", session: "default"),
                                      label: "Cloud", health: .online, target: "test-cloud")

    private func snapshot() throws -> SessionSnapshot {
        var workspaces: [[String: Any]] = []
        var tabs: [[String: Any]] = []
        var panes: [[String: Any]] = []
        for index in 1...2 {
            let w = "w\(index)"
            workspaces.append(["workspace_id": w, "number": index, "label": w,
                "focused": index == 1, "pane_count": 2, "tab_count": 2,
                "active_tab_id": "\(w):t1", "agent_status": "idle"])
            for t in 1...2 {
                let tab = "\(w):t\(t)", pane = "\(w):p\(t)"
                tabs.append(["tab_id": tab, "workspace_id": w, "number": t, "label": tab,
                    "focused": index == 1 && t == 1, "pane_count": 1, "agent_status": "idle"])
                panes.append(["pane_id": pane, "terminal_id": "\(pane)-term", "workspace_id": w,
                    "tab_id": tab, "focused": index == 1 && t == 1, "cwd": "/tmp",
                    "agent_status": "idle", "revision": 1])
            }
        }
        return try JSONDecoder().decode(SessionSnapshot.self, from: JSONSerialization.data(withJSONObject: [
            "version": "test", "protocol": 22, "workspaces": workspaces, "tabs": tabs,
            "panes": panes, "layouts": [], "focused_workspace_id": "w1",
            "focused_tab_id": "w1:t1", "focused_pane_id": "w1:p1"
        ]))
    }

    private func fixture() throws -> (MachineNavigationController, RaiModel, RaiModel) {
        _ = NSApplication.shared
        let defaultsName = "rai-machine-navigation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: defaultsName) }
        let primary = RaiModel(client: HerdrClient(socketPath: "/nonexistent/navigation-local.sock"), userDefaults: defaults)
        let remoteModel = RaiModel(client: HerdrClient(socketPath: "/nonexistent/navigation-remote.sock"),
                                   userDefaults: defaults, machineEntry: remote)
        let snapshot = try snapshot()
        primary.adoptSnapshotForTesting(snapshot, connected: true)
        remoteModel.adoptSnapshotForTesting(snapshot, connected: true)
        primary.selectedPaneID = "w1:p1"
        remoteModel.selectedPaneID = "w1:p1"
        let navigation = MachineNavigationController(primaryModel: primary, directory: MachineDirectory(),
                                                       connects: false, makeModel: { _ in remoteModel })
        navigation.reconcile([remote])
        return (navigation, primary, remoteModel)
    }

    func testSameResourceIDsRemainScopedToTheirMachine() throws {
        let (navigation, primary, remoteModel) = try fixture()
        navigation.selectSpace(.init(endpoint: remote.endpoint, workspaceID: "w2"))
        XCTAssertTrue(navigation.activeModel === remoteModel)
        XCTAssertEqual(remoteModel.selectedWorkspace?.workspaceID, "w2")
        XCTAssertEqual(primary.selectedWorkspace?.workspaceID, "w1")
        navigation.selectMachine(try XCTUnwrap(primary.currentMachineEntry).endpoint)
        XCTAssertTrue(navigation.activeModel === primary)
        XCTAssertEqual(primary.selectedTabID, "w1:t1")
    }

    func testNextAndPreviousCrossMachineGroupsAndWrap() throws {
        let (navigation, primary, remoteModel) = try fixture()
        navigation.cycleSpace(by: 1)
        XCTAssertTrue(navigation.activeModel === primary)
        XCTAssertEqual(primary.selectedWorkspace?.workspaceID, "w2")
        navigation.cycleSpace(by: 1)
        XCTAssertTrue(navigation.activeModel === remoteModel)
        XCTAssertEqual(remoteModel.selectedWorkspace?.workspaceID, "w1")
        navigation.cycleSpace(by: 1)
        navigation.cycleSpace(by: 1)
        XCTAssertTrue(navigation.activeModel === primary)
        XCTAssertEqual(primary.selectedWorkspace?.workspaceID, "w1")
        navigation.cycleSpace(by: -1)
        XCTAssertTrue(navigation.activeModel === remoteModel)
        XCTAssertEqual(remoteModel.selectedWorkspace?.workspaceID, "w2")
    }

    func testCollapseDoesNotSwitchAndKeyboardRevealsDestination() throws {
        let (navigation, _, remoteModel) = try fixture()
        navigation.selectMachine(remote.endpoint)
        navigation.toggleCollapsed(remote.endpoint)
        XCTAssertTrue(navigation.activeModel === remoteModel)
        XCTAssertTrue(navigation.collapsedMachines.contains(remote.endpoint))
        navigation.cycleSpace(by: 1)
        XCTAssertFalse(navigation.collapsedMachines.contains(remote.endpoint))
    }

    func testReturningToSpaceRestoresItsLastSelectedTab() throws {
        let (navigation, _, remoteModel) = try fixture()
        navigation.selectMachine(remote.endpoint)
        remoteModel.selectedPaneID = "w1:p2"
        navigation.selectSpace(.init(endpoint: remote.endpoint, workspaceID: "w2"))
        navigation.selectSpace(.init(endpoint: remote.endpoint, workspaceID: "w1"))
        XCTAssertEqual(remoteModel.selectedTabID, "w1:t2")
    }

    func testCatalogRefreshAndReconnectNeverSelectAnotherMachine() throws {
        let (navigation, primary, remoteModel) = try fixture()
        navigation.selectMachine(remote.endpoint)
        navigation.reconcile([remote])
        XCTAssertTrue(navigation.activeModel === remoteModel)
        XCTAssertEqual(primary.selectedPaneID, "w1:p1")
        var renamed = remote
        renamed.label = "Renamed"
        navigation.reconcile([renamed])
        XCTAssertTrue(navigation.activeModel === remoteModel)
        XCTAssertEqual(navigation.entries.last?.label, "Renamed")
    }

    func testRemovingSelectedMachineReturnsToLocal() throws {
        let (navigation, primary, _) = try fixture()
        navigation.selectMachine(remote.endpoint)
        navigation.reconcile([])
        XCTAssertTrue(navigation.activeModel === primary)
        XCTAssertEqual(navigation.entries.count, 1)
    }

    func testOfflineMachineIsSkippedByKeyboard() throws {
        let (navigation, primary, remoteModel) = try fixture()
        remoteModel.adoptSnapshotForTesting(try snapshot(), connected: false)
        navigation.cycleSpace(by: -1)
        XCTAssertTrue(navigation.activeModel === primary)
        XCTAssertEqual(primary.selectedWorkspace?.workspaceID, "w2")
    }

    func testNewDragCannotReuseAnotherMachinesMatchingIDs() throws {
        let (_, primary, remoteModel) = try fixture()
        primary.draggedTabID = "w1:t1"
        XCTAssertTrue(primary.ownsDrag)
        remoteModel.draggedTabID = "w1:t1"
        XCTAssertTrue(remoteModel.ownsDrag)
        XCTAssertFalse(primary.ownsDrag)
        XCTAssertNil(primary.draggedTabID)
    }
}
