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
        let model = RaiMixedViewModel(store: store)

        XCTAssertTrue(model.addSpace(space))
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

    func testModelReordersAndPersistsMixedPaneSlots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RaiCompositionStore(fileURL: root.appendingPathComponent("mixed-view.json"))
        let space = RaiSpace(label: "Local", source: .init(endpoint: local, workspaceID: "w1"))
        let first = RaiPaneSlot(source: .init(endpoint: local, workspaceID: "w1", tabID: "t1", paneID: "p1"))
        let second = RaiPaneSlot(source: .init(endpoint: local, workspaceID: "w1", tabID: "t1", paneID: "p2"))
        let tab = RaiTab(label: "Mixed", paneSlots: [first, second])
        let model = RaiMixedViewModel(composition: RaiComposition(spaces: [space]), store: store)
        XCTAssertTrue(model.addTab(tab, to: space.id))
        XCTAssertTrue(model.movePaneSlot(second.id, before: first.id, in: tab.id))
        XCTAssertEqual(model.composition.tab(id: tab.id)?.paneSlots.map(\.id), [second.id, first.id])
        XCTAssertTrue(model.save())

        let reloaded = RaiMixedViewModel(store: store)
        XCTAssertTrue(reloaded.load())
        XCTAssertEqual(reloaded.composition.tab(id: tab.id)?.paneSlots.map(\.id), [second.id, first.id])
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
}
