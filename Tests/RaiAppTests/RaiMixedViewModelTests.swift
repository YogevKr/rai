import Foundation
import RaiCore
import XCTest
@testable import RaiApp

@MainActor
final class RaiMixedViewModelTests: XCTestCase {
    private let local = MachineEndpoint(session: "default")

    func testModelLoadsSavesAndProjectsEndpointSnapshots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RaiCompositionStore(fileURL: root.appendingPathComponent("mixed-view.json"))
        let space = RaiSpace(label: "Local", source: .init(endpoint: local, workspaceID: "w1"))
        let slot = RaiPaneSlot(source: .init(endpoint: local, workspaceID: "w1", tabID: "t1", paneID: "p1"))
        let model = RaiMixedViewModel(composition: RaiComposition(spaces: [space]), store: store)
        let tab = RaiTab(label: "Mixed", paneSlots: [slot])
        XCTAssertTrue(model.addTab(tab, to: space.id))
        XCTAssertTrue(model.save())

        let reloaded = RaiMixedViewModel(store: store)
        XCTAssertTrue(reloaded.load())
        XCTAssertEqual(reloaded.composition, model.composition)

        reloaded.receive(endpoint: local, connectionID: "connection", snapshot: try snapshot())
        XCTAssertEqual(try reloaded.resolutions(for: tab.id), [.ready(.init(
            slotID: slot.id,
            source: slot.source,
            connectionID: "connection",
            bootID: "boot",
            terminalID: "term-1"
        ))])
    }

    func testDisconnectKeepsSavedSlotsVisibleAsOffline() throws {
        let space = RaiSpace(label: "Local", source: .init(endpoint: local, workspaceID: "w1"))
        let slot = RaiPaneSlot(source: .init(endpoint: local, workspaceID: "w1", tabID: "t1", paneID: "p1"))
        let tab = RaiTab(paneSlots: [slot])
        let model = RaiMixedViewModel(composition: RaiComposition(spaces: [space]))
        XCTAssertTrue(model.addTab(tab, to: space.id))
        model.receive(endpoint: local, connectionID: "connection", snapshot: try snapshot())
        model.disconnect(endpoint: local)
        XCTAssertEqual(try model.resolutions(for: tab.id), [.endpointOffline])
    }

    func testInvalidCompositionDoesNotReplaceCurrentState() {
        let model = RaiMixedViewModel()
        let original = model.composition
        let duplicate = RaiSpace(
            label: "Duplicate",
            source: .init(endpoint: local, workspaceID: "w1")
        )
        var invalid = original
        invalid.spaces = [duplicate, duplicate]
        XCTAssertFalse(model.replace(invalid))
        XCTAssertEqual(model.composition, original)
        XCTAssertNotNil(model.error)
    }

    func testNewTabUsesSelectedSpaceAndFallsBackWhenSelectionIsMissing() throws {
        let first = RaiSpace(source: .init(endpoint: local, workspaceID: "w1"), tabs: [RaiTab()])
        let second = RaiSpace(source: .init(endpoint: local, workspaceID: "w2"), tabs: [RaiTab()])
        let model = RaiMixedViewModel(composition: RaiComposition(spaces: [first, second]))
        let added = try XCTUnwrap(model.newTab(after: second.tabs[0].id))
        XCTAssertEqual(model.composition.spaces[0].tabs, first.tabs)
        XCTAssertEqual(model.composition.spaces[1].tabs.last?.id, added)
        let fallback = try XCTUnwrap(model.newTab(after: UUID()))
        XCTAssertEqual(model.composition.spaces[0].tabs.last?.id, fallback)
        XCTAssertNil(RaiMixedViewModel().newTab(after: nil))
    }

    func testShowingCreatedInstanceWorkspaceAddsItsSourceTab() throws {
        let endpoint = MachineEndpoint(profileID: "machine", session: "default")
        let machine = MachineEntry(endpoint: endpoint, label: "Local", health: .online)
        let source = try sourceSnapshot(workspaceID: "w4", tabID: "w4:t1", paneID: "w4:p1")
        let workspace = try XCTUnwrap(
            InstanceWorkspace.entries(
                machines: [machine],
                snapshots: [endpoint: source],
                excluding: nil
            ).first
        )
        let sourceTab = try XCTUnwrap(workspace.tabs.first)
        let model = RaiMixedViewModel()

        let mixedTabID = model.showSourceTab(sourceTab, spaceLabel: workspace.label)

        let mixedSpace = try XCTUnwrap(model.composition.spaces.first)
        XCTAssertEqual(mixedSpace.source, sourceTab.workspace)
        XCTAssertEqual(mixedSpace.tabs.first?.id, mixedTabID)
        XCTAssertEqual(mixedSpace.tabs.first?.paneSlots.first?.source, sourceTab.panes.first)
    }

    func testRemovingSourceTabKeepsHerdrSourceOutOfRaiComposition() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RaiCompositionStore(fileURL: root.appendingPathComponent("mixed-view.json"))
        let reference = RaiWorkspaceReference(endpoint: local, workspaceID: "w1")
        let first = RaiPaneReference(endpoint: local, workspaceID: "w1", tabID: "t1", paneID: "p1")
        let second = RaiPaneReference(endpoint: local, workspaceID: "w1", tabID: "t2", paneID: "p2")
        let space = RaiSpace(
            source: reference,
            tabs: [
                RaiTab(label: "One", paneSlots: [RaiPaneSlot(source: first)]),
                RaiTab(label: "Two", paneSlots: [RaiPaneSlot(source: second)]),
            ]
        )
        let model = RaiMixedViewModel(composition: RaiComposition(spaces: [space]), store: store)

        XCTAssertTrue(model.removeSourceTab(reference, tabID: "t1"))
        XCTAssertEqual(model.composition.spaces.count, 1)
        XCTAssertEqual(model.composition.spaces[0].tabs.map(\.label), ["Two"])
    }

    func testRemovingLastSourceTabRemovesOnlyTheRaiSpace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RaiCompositionStore(fileURL: root.appendingPathComponent("mixed-view.json"))
        let reference = RaiWorkspaceReference(endpoint: local, workspaceID: "w1")
        let source = RaiPaneReference(endpoint: local, workspaceID: "w1", tabID: "t1", paneID: "p1")
        let space = RaiSpace(source: reference, tabs: [RaiTab(paneSlots: [RaiPaneSlot(source: source)])])
        let model = RaiMixedViewModel(composition: RaiComposition(spaces: [space]), store: store)

        XCTAssertTrue(model.removeSourceTab(reference, tabID: "t1"))
        XCTAssertTrue(model.composition.spaces.isEmpty)
    }

    func testRemovingSourceWorkspaceDoesNotAffectAnotherRaiSpace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RaiCompositionStore(fileURL: root.appendingPathComponent("mixed-view.json"))
        let first = RaiWorkspaceReference(endpoint: local, workspaceID: "w1")
        let second = RaiWorkspaceReference(endpoint: local, workspaceID: "w2")
        let model = RaiMixedViewModel(
            composition: RaiComposition(spaces: [RaiSpace(source: first), RaiSpace(source: second)]),
            store: store
        )

        XCTAssertTrue(model.removeSourceWorkspace(first))
        XCTAssertEqual(model.composition.spaces.map(\.source), [second])
    }

    private func snapshot() throws -> HerdrEndpointSnapshot {
        let object: [String: Any] = [
            "boot_id": "boot",
            "revision": 1,
            "focused_workspace_id": "w1",
            "focused_tab_id": "t1",
            "focused_pane_id": "p1",
            "workspaces": [["workspace_id": "w1"]],
            "tabs": [["tab_id": "t1", "workspace_id": "w1"]],
            "panes": [[
                "pane_id": "p1", "terminal_id": "term-1",
                "workspace_id": "w1", "tab_id": "t1", "focused": true,
                "agent_status": "idle", "revision": 1,
            ]],
        ]
        return try JSONDecoder().decode(
            HerdrEndpointSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    private func sourceSnapshot(
        workspaceID: String,
        tabID: String,
        paneID: String
    ) throws -> HerdrEndpointSnapshot {
        let object: [String: Any] = [
            "boot_id": "boot",
            "revision": 1,
            "focused_workspace_id": workspaceID,
            "focused_tab_id": tabID,
            "focused_pane_id": paneID,
            "workspaces": [[
                "workspace_id": workspaceID,
                "label": "Created Local",
                "active_tab_id": tabID,
            ]],
            "tabs": [[
                "tab_id": tabID,
                "workspace_id": workspaceID,
                "label": "default",
            ]],
            "panes": [[
                "pane_id": paneID,
                "terminal_id": "term-1",
                "workspace_id": workspaceID,
                "tab_id": tabID,
                "focused": true,
                "agent_status": "idle",
                "revision": 1,
            ]],
        ]
        return try JSONDecoder().decode(
            HerdrEndpointSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }
}
