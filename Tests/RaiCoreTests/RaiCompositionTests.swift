import XCTest
@testable import RaiCore

final class RaiCompositionTests: XCTestCase {
    private let local = MachineEndpoint(session: "default")
    private let remote = MachineEndpoint(profileID: String(repeating: "a", count: 32), session: "default")

    private func space(_ id: UUID = UUID(), endpoint: MachineEndpoint, workspace: String) -> RaiSpace {
        RaiSpace(
            id: id,
            label: workspace,
            source: RaiWorkspaceReference(endpoint: endpoint, workspaceID: workspace)
        )
    }

    private func slot(endpoint: MachineEndpoint, workspace: String, tab: String, pane: String) -> RaiPaneSlot {
        RaiPaneSlot(source: RaiPaneReference(
            endpoint: endpoint, workspaceID: workspace, tabID: tab, paneID: pane
        ))
    }

    func testOneTabCanMixPanesFromTwoHerdrSpaces() throws {
        let first = space(endpoint: local, workspace: "local-work")
        let second = space(endpoint: remote, workspace: "remote-work")
        let mixedTab = RaiTab(label: "Review", paneSlots: [
            slot(endpoint: local, workspace: "local-work", tab: "t1", pane: "p1"),
            slot(endpoint: remote, workspace: "remote-work", tab: "t2", pane: "p9"),
        ])
        var composition = RaiComposition(spaces: [first, second])
        try composition.addTab(mixedTab, to: first.id)

        try composition.validate()
        XCTAssertEqual(composition.tabs.count, 1)
        XCTAssertEqual(Set(composition.paneSlots.map(\.source.endpoint)), [local, remote])
        XCTAssertEqual(composition.paneSlots.map(\.source.workspaceID), ["local-work", "remote-work"])
    }

    func testDuplicatePaneSourceIsRejectedOnlyWithinOneTab() throws {
        let sourceSpace = space(endpoint: local, workspace: "work")
        let source = slot(endpoint: local, workspace: "work", tab: "t1", pane: "p1")
        var composition = RaiComposition(spaces: [sourceSpace])
        XCTAssertThrowsError(try composition.addTab(
            RaiTab(paneSlots: [source, RaiPaneSlot(source: source.source)]), to: sourceSpace.id
        )) { error in
            XCTAssertEqual(error as? RaiCompositionError, .duplicateSource(source.source))
        }

        try composition.addTab(RaiTab(paneSlots: [source]), to: sourceSpace.id)
        try composition.addTab(RaiTab(paneSlots: [RaiPaneSlot(source: source.source)]), to: sourceSpace.id)
        XCTAssertEqual(composition.tabs.count, 2)
    }

    func testPaneSlotsCanBeReorderedWithoutChangingTheirSources() throws {
        let sourceSpace = space(endpoint: local, workspace: "work")
        let first = slot(endpoint: local, workspace: "work", tab: "t1", pane: "p1")
        let second = slot(endpoint: remote, workspace: "remote", tab: "t2", pane: "p2")
        var composition = RaiComposition(spaces: [sourceSpace, space(endpoint: remote, workspace: "remote")])
        let tab = RaiTab(paneSlots: [first, second])
        try composition.addTab(tab, to: sourceSpace.id)

        try composition.movePaneSlot(id: second.id, before: first.id, in: tab.id)
        XCTAssertEqual(composition.tab(id: tab.id)?.paneSlots.map(\.id), [second.id, first.id])

        try composition.movePaneSlot(id: second.id, before: nil, in: tab.id)
        XCTAssertEqual(composition.tab(id: tab.id)?.paneSlots.map(\.id), [first.id, second.id])
        XCTAssertEqual(composition.paneSlot(id: first.id)?.source, first.source)
        XCTAssertEqual(composition.paneSlot(id: second.id)?.source, second.source)
    }

    func testPaneSlotReorderRejectsForeignTarget() throws {
        let sourceSpace = space(endpoint: local, workspace: "work")
        let otherSpace = space(endpoint: remote, workspace: "remote")
        let first = slot(endpoint: local, workspace: "work", tab: "t1", pane: "p1")
        let second = slot(endpoint: remote, workspace: "remote", tab: "t2", pane: "p2")
        var composition = RaiComposition(spaces: [sourceSpace, otherSpace])
        let tab = RaiTab(paneSlots: [first])
        let otherTab = RaiTab(paneSlots: [second])
        try composition.addTab(tab, to: sourceSpace.id)
        try composition.addTab(otherTab, to: otherSpace.id)

        XCTAssertThrowsError(try composition.movePaneSlot(id: first.id, before: second.id, in: tab.id)) { error in
            XCTAssertEqual(error as? RaiCompositionError, .missingSlot(second.id))
        }
        XCTAssertEqual(composition.tab(id: tab.id)?.paneSlots.map(\.id), [first.id])
    }

    func testTabColumnCountDefaultsForOlderSavedTabsAndValidatesChanges() throws {
        let tabID = UUID()
        let legacy = try JSONSerialization.data(withJSONObject: [
            "id": tabID.uuidString,
            "label": "Legacy",
            "paneSlots": [],
        ])
        let decoded = try JSONDecoder().decode(RaiTab.self, from: legacy)
        XCTAssertEqual(decoded.columnCount, 2)

        var composition = RaiComposition(spaces: [space(endpoint: local, workspace: "work")])
        try composition.addTab(decoded, to: composition.spaces[0].id)
        try composition.setColumnCount(3, for: tabID)
        XCTAssertEqual(composition.tab(id: tabID)?.columnCount, 3)
        XCTAssertThrowsError(try composition.setColumnCount(0, for: tabID)) { error in
            XCTAssertEqual(error as? RaiCompositionError, .invalid("The Rai tab column count is invalid."))
        }
    }

    func testSourceIdentityDoesNotUseLabelsOrConnectionIDs() throws {
        let endpoint = MachineEndpoint(profileID: "profile", session: "default")
        let one = RaiPaneReference(endpoint: endpoint, workspaceID: "w", tabID: "t", paneID: "p")
        let two = RaiPaneReference(endpoint: endpoint, workspaceID: "w", tabID: "t", paneID: "p")
        XCTAssertEqual(one, two)

        var composition = RaiComposition(spaces: [
            space(endpoint: endpoint, workspace: "w")
        ])
        let id = UUID()
        let slot = RaiPaneSlot(id: id, label: "Old label", source: one)
        try composition.addTab(RaiTab(label: "Old tab", paneSlots: [slot]), to: composition.spaces[0].id)
        try composition.attachPaneSlot(id: id, connectionID: "connection-1", bootID: "boot-1")
        XCTAssertTrue(try XCTUnwrap(composition.paneSlot(id: id)).accepts(connectionID: "connection-1", bootID: "boot-1"))
        XCTAssertFalse(try XCTUnwrap(composition.paneSlot(id: id)).accepts(connectionID: "connection-2", bootID: "boot-1"))
        XCTAssertFalse(try XCTUnwrap(composition.paneSlot(id: id)).accepts(connectionID: "connection-1", bootID: "boot-2"))

        let route = try composition.routePaneSlot(
            id: id, endpoint: endpoint, connectionID: "connection-1", bootID: "boot-1"
        )
        XCTAssertEqual(route.source, one)
        XCTAssertThrowsError(try composition.routePaneSlot(
            id: id, endpoint: local, connectionID: "connection-1", bootID: "boot-1"
        )) { error in
            XCTAssertEqual(error as? RaiCompositionError, .staleAttachment(id))
        }
    }

    func testRuntimeAttachmentIsClearedByCodableRoundTrip() throws {
        let sourceSpace = space(endpoint: local, workspace: "work")
        let id = UUID()
        let sourceSlot = RaiPaneSlot(id: id, source: RaiPaneReference(
            endpoint: local, workspaceID: "work", tabID: "t1", paneID: "p1"
        ))
        var composition = RaiComposition(spaces: [sourceSpace])
        try composition.addTab(RaiTab(paneSlots: [sourceSlot]), to: sourceSpace.id)
        try composition.attachPaneSlot(id: id, connectionID: "connection", bootID: "boot")

        let data = try JSONEncoder().encode(composition)
        let decoded = try JSONDecoder().decode(RaiComposition.self, from: data)
        XCTAssertNil(decoded.paneSlot(id: id)?.attachment)
        XCTAssertEqual(decoded.paneSlot(id: id)?.source.paneID, "p1")
    }

    func testStoreCreatesDirectoryAndLoadsComposition() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RaiCompositionStore(fileURL: root.appendingPathComponent("nested/mixed-view.json"))
        XCTAssertNil(try store.load())

        let sourceSpace = space(endpoint: local, workspace: "work")
        var composition = RaiComposition(label: "Daily", spaces: [sourceSpace])
        try composition.addTab(RaiTab(label: "Main", paneSlots: [
            slot(endpoint: local, workspace: "work", tab: "t1", pane: "p1")
        ]), to: sourceSpace.id)
        try store.save(composition)

        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertEqual(try store.load(), composition)
    }

    func testDecodeRejectsOversizedCollectionAndUnregisteredSource() throws {
        let sourceSpace = space(endpoint: local, workspace: "work")
        let tooMany = RaiComposition(spaces: (0..<RaiCompositionLimits.maxSpaces + 1).map { _ in
            space(endpoint: MachineEndpoint(session: "s\(UUID().uuidString)"), workspace: "work")
        })
        XCTAssertThrowsError(try JSONEncoder().encode(tooMany))

        let foreign = RaiTab(paneSlots: [slot(endpoint: remote, workspace: "missing", tab: "t", pane: "p")])
        let invalid = RaiComposition(label: "Default", spaces: [sourceSpace])
        var data = try JSONEncoder().encode(invalid)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["spaces"] = [[
            "id": sourceSpace.id.uuidString,
            "label": sourceSpace.label,
            "source": ["endpoint": ["session": "default"], "workspaceID": "work"],
            "tabs": [[
                "id": foreign.id.uuidString,
                "label": foreign.label,
                "paneSlots": [[
                    "id": foreign.paneSlots[0].id.uuidString,
                    "source": ["endpoint": ["profileID": String(repeating: "a", count: 32), "session": "default"],
                               "workspaceID": "missing", "tabID": "t", "paneID": "p"]
                ]]
            ]]
        ]]
        data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(RaiComposition.self, from: data))
    }

    func testProjectionResolvesTerminalIDOnlyWhenAllSourceIDsMatch() throws {
        let sourceSpace = space(endpoint: local, workspace: "work")
        let pane = slot(endpoint: local, workspace: "work", tab: "t1", pane: "p1")
        var composition = RaiComposition(spaces: [sourceSpace])
        try composition.addTab(RaiTab(paneSlots: [pane]), to: sourceSpace.id)
        let snapshot = try endpointSnapshot(paneID: "p1", workspaceID: "work", tabID: "t1", terminalID: "term-1")
        let projection = RaiEndpointProjection(endpoint: local, connectionID: "connection", snapshot: snapshot)

        guard case .ready(let target) = try composition.resolvePaneSlot(id: pane.id, endpointProjection: projection) else {
            return XCTFail("The matching pane must resolve to a terminal target.")
        }
        XCTAssertEqual(target.terminalID, "term-1")
        XCTAssertEqual(target.bootID, "boot")

        let changed = try endpointSnapshot(paneID: "p1", workspaceID: "other", tabID: "t1", terminalID: "term-1")
        XCTAssertEqual(
            try composition.resolvePaneSlot(
                id: pane.id,
                endpointProjection: RaiEndpointProjection(endpoint: local, connectionID: "connection", snapshot: changed)
            ),
            .paneIdentityChanged
        )
    }

    func testProjectionKeepsOfflineAndMissingSourcesVisible() throws {
        let sourceSpace = space(endpoint: remote, workspace: "work")
        let pane = slot(endpoint: remote, workspace: "work", tab: "t1", pane: "p1")
        var composition = RaiComposition(spaces: [sourceSpace])
        try composition.addTab(RaiTab(paneSlots: [pane]), to: sourceSpace.id)
        XCTAssertEqual(try composition.resolvePaneSlot(id: pane.id, endpointProjection: nil), .endpointOffline)

        let snapshot = try endpointSnapshot(paneID: "p9", workspaceID: "work", tabID: "t1", terminalID: "term-9")
        XCTAssertEqual(
            try composition.resolvePaneSlot(
                id: pane.id,
                endpointProjection: RaiEndpointProjection(endpoint: remote, connectionID: "connection", snapshot: snapshot)
            ),
            .paneMissing
        )
    }

    private func endpointSnapshot(
        paneID: String,
        workspaceID: String,
        tabID: String,
        terminalID: String
    ) throws -> HerdrEndpointSnapshot {
        let object: [String: Any] = [
            "boot_id": "boot",
            "revision": 1,
            "focused_workspace_id": workspaceID,
            "focused_tab_id": tabID,
            "focused_pane_id": paneID,
            "workspaces": [["workspace_id": workspaceID]],
            "tabs": [["tab_id": tabID, "workspace_id": workspaceID]],
            "panes": [[
                "pane_id": paneID,
                "terminal_id": terminalID,
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
