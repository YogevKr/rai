import Foundation
import XCTest
@testable import RaiCore

final class EndpointPluginTests: XCTestCase {
    func testWindowTitleWirePreservesResetAndRejectsUnsafeTitles() throws {
        XCTAssertEqual(try HerdrEndpointWire.decode(Data([6, 0])), .windowTitle(nil))
        var title = Data([6, 1]); HerdrEndpointWire.appendString("Build · שלום", to: &title)
        XCTAssertEqual(try HerdrEndpointWire.decode(title), .windowTitle("Build · שלום"))
        for text in ["bad\nline", "bad\u{1b}", String(repeating: "x", count: 4097)] {
            var frame = Data([6, 1]); HerdrEndpointWire.appendString(text, to: &frame)
            XCTAssertThrowsError(try HerdrEndpointWire.decode(frame))
        }
        XCTAssertThrowsError(try HerdrEndpointWire.decode(Data([6, 2])))
        XCTAssertThrowsError(try HerdrEndpointWire.decode(Data([6, 0, 0])))
    }

    func testSemanticNotificationWirePreservesFields() throws {
        var frame = Data([14, 0])
        HerdrEndpointWire.appendString("Needs attention", to: &frame)
        frame.append(1); HerdrEndpointWire.appendString("Build failed", to: &frame)
        frame.append(contentsOf: [1, 1])
        for value in ["codex", "w1", "w1:t1", "w1:p1"] {
            frame.append(1); HerdrEndpointWire.appendString(value, to: &frame)
        }
        frame.append(contentsOf: [1, 1])
        guard case .notification(let notice) = try HerdrEndpointWire.decode(frame) else { return XCTFail("Expected notification") }
        XCTAssertEqual(notice.kind, .needsAttention)
        XCTAssertEqual(notice.title, "Needs attention")
        XCTAssertEqual(notice.body, "Build failed")
        XCTAssertEqual(notice.sound, .request)
        XCTAssertEqual(notice.agent, "codex")
        XCTAssertEqual(notice.workspaceID, "w1")
        XCTAssertEqual(notice.tabID, "w1:t1")
        XCTAssertEqual(notice.paneID, "w1:p1")
        XCTAssertEqual(notice.position, .topRight)
        let decoded = try JSONDecoder().decode(EndpointNotification.self, from: JSONEncoder().encode(notice))
        XCTAssertEqual(decoded, notice)
        frame.append(0)
        XCTAssertThrowsError(try HerdrEndpointWire.decode(frame))
    }

    func testMalformedNotificationsAndMandatoryErrors() throws {
        for bytes: [UInt8] in [[14], [14, 4], [14, 0, 0, 2], [14, 0, 0, 0, 1, 2]] {
            XCTAssertThrowsError(try HerdrEndpointWire.decode(Data(bytes)))
        }
        var frame = Data([15]); HerdrEndpointWire.appendString("Endpoint failed", to: &frame)
        guard case .notification(let notice) = try HerdrEndpointWire.decode(frame) else { return XCTFail("Expected error") }
        XCTAssertEqual(notice.kind, .error)
        XCTAssertEqual(notice.title, "Endpoint failed")
    }

    func testSnapshotKeepsAgentOrderStatusSegmentsAndEmptyFilteredView() throws {
        let source = #"{"boot_id":"boot","revision":1,"agent_view_label":"Working","agent_order":["p2","missing","p2","p1"],"tab_bar_right":[{"text":"cost 3","accent":true}],"tab_bar_right_separator":" / ","agents":[{"pane_id":"p1"},{"pane_id":"p2"}]}"#
        let snapshot = try JSONDecoder().decode(HerdrEndpointSnapshot.self, from: Data(source.utf8))
        XCTAssertEqual(snapshot.visibleAgents.compactMap { $0.objectValue?["pane_id"]?.stringValue }, ["p2", "p1"])
        XCTAssertEqual(snapshot.tabBarRightSeparator, " / ")
        XCTAssertEqual(snapshot.tabBarRight.first?.objectValue?["accent"], .bool(true))
        XCTAssertEqual(try JSONDecoder().decode(HerdrEndpointSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
        let empty = source.replacingOccurrences(of: #"["p2","missing","p2","p1"]"#, with: "[]")
        XCTAssertTrue(try JSONDecoder().decode(HerdrEndpointSnapshot.self, from: Data(empty.utf8)).visibleAgents.isEmpty)
    }

    func testTypedPluginAndAgentRequestsMatchSupportedContracts() throws {
        XCTAssertEqual(try EndpointPluginOperation.enable("example.plugin").rpc().method, "plugin.enable")
        XCTAssertEqual(try EndpointPluginOperation.disable("example.plugin").rpc().params, ["plugin_id": .string("example.plugin")])
        XCTAssertEqual(try EndpointPluginOperation.integrations.rpc().method, "integration.list")
        XCTAssertEqual(try EndpointPluginOperation.installIntegration("codex").rpc().params, ["target": .string("codex")])
        XCTAssertThrowsError(try EndpointPluginOperation.installIntegration("invalid").rpc())
        XCTAssertThrowsError(try EndpointPluginOperation.enable("").rpc())
        XCTAssertThrowsError(try EndpointPluginOperation.prepareInstall(source: "owner/repo", reference: "main").rpc())
        let spec = AgentViewSetParams(source: "rai.native", label: "Working", filter: .equal(field: .builtin(.status), value: .string("working")))
        let rpc = try EndpointPluginOperation.setAgentView(spec).rpc()
        XCTAssertEqual(rpc.method, "agent.view.set")
        XCTAssertEqual(rpc.params["filter"]?.objectValue?["op"], .string("eq"))
        XCTAssertEqual(try EndpointPluginOperation.clearAgentView.rpc().method, "agent.view.clear")
        let request = EndpointPluginRequest(bootID: "boot", operation: .setAgentView(spec))
        XCTAssertEqual(try JSONDecoder().decode(EndpointPluginRequest.self, from: JSONEncoder().encode(request)), request)
    }

    func testPluginInventoryRejectsIncompleteAndDuplicateRecords() throws {
        let plugin: JSONValue = .object(["plugin_id": .string("p"), "name": .string("Plugin"), "version": .string("1"), "enabled": .bool(true)])
        let list = try EndpointInstalledPlugin.list(.object(["plugins": .array([plugin])]))
        XCTAssertEqual(list.first?.name, "Plugin")
        XCTAssertEqual(list.first?.version, "1")
        XCTAssertThrowsError(try EndpointInstalledPlugin.list(.object(["plugins": .array([plugin, plugin])])))
        XCTAssertThrowsError(try EndpointInstalledPlugin.list(.object(["plugins": .array([.object([:])])])))
        XCTAssertThrowsError(try EndpointInstalledPlugin.list(.object([:])))
    }

    func testPluginPaneLaunchRequiresEnabledDeclaredEntryAndKeepsNativeContext() throws {
        let snapshot = try JSONDecoder().decode(HerdrEndpointSnapshot.self, from: Data(
            #"{"boot_id":"boot","revision":3,"focused_workspace_id":"w1","focused_tab_id":"t1","focused_pane_id":"p1"}"#.utf8))
        var data: [String: JSONValue] = ["plugin_id": .string("example.plugin"), "name": .string("Example"),
            "enabled": .bool(true), "panes": .array([.object(["id": .string("popup"), "title": .string("Popup"),
                "placement": .string("popup"), "command": .array([.string("private-command")])])])]
        let plugin = try XCTUnwrap(EndpointInstalledPlugin(.object(data)))
        let pane = try XCTUnwrap(plugin.panes.first)
        let invocation = try XCTUnwrap(EndpointPluginPaneInvocation(plugin: plugin, pane: pane, snapshot: snapshot))
        let operation = EndpointPluginOperation.openPane(invocation)
        XCTAssertEqual(operation.endpointMethod, "plugin.pane.open")
        XCTAssertEqual(try operation.rpc().params, ["plugin_id": .string("example.plugin"),
            "entrypoint": .string("popup"), "focus": .bool(true)])
        XCTAssertNoThrow(try invocation.validate(in: snapshot))
        let moved = try JSONDecoder().decode(HerdrEndpointSnapshot.self, from: Data(
            #"{"boot_id":"boot","revision":4,"focused_workspace_id":"w1","focused_tab_id":"t1","focused_pane_id":"p2"}"#.utf8))
        XCTAssertThrowsError(try invocation.validate(in: moved))
        XCTAssertEqual(try JSONDecoder().decode(EndpointPluginOperation.self, from: JSONEncoder().encode(operation)), operation)
        data["enabled"] = .bool(false)
        XCTAssertNil(EndpointPluginPaneInvocation(plugin: try XCTUnwrap(EndpointInstalledPlugin(.object(data))), pane: pane, snapshot: snapshot))
        data["enabled"] = .bool(true); data["panes"] = .array([])
        XCTAssertNil(EndpointPluginPaneInvocation(plugin: try XCTUnwrap(EndpointInstalledPlugin(.object(data))), pane: pane, snapshot: snapshot))
    }

    func testPluginPaneInventoryRejectsInvalidOrDuplicateEntrypoints() throws {
        XCTAssertNil(EndpointPluginPane(.object(["id": .string("bad\nentry")])))
        XCTAssertNil(EndpointPluginPane(.object(["id": .string("")])))
        let entry: JSONValue = .object(["id": .string("popup"), "title": .string("Popup")])
        let plugin = try XCTUnwrap(EndpointInstalledPlugin(.object(["plugin_id": .string("p"), "name": .string("P"),
            "enabled": .bool(true), "panes": .array([entry, entry])])))
        XCTAssertTrue(plugin.panes.isEmpty)
    }

    private func linkSurface(revision: Int = 2, offset: Int = 0, url: String = "plugin://open") throws -> HerdrEndpointSurface {
        let rect: [String: Any] = ["x": 1, "y": 0, "width": 2, "height": 1]
        let cell: [String: Any] = ["symbol": "X", "foreground": 0, "background": 0, "modifiers": 0, "skip": false, "hyperlink": 0]
        let object: [String: Any] = [
            "bootID": "boot", "projectionRevision": 1, "revision": 1,
            "grid": ["width": 3, "height": 1, "cells": [cell, cell, cell], "hyperlinks": [url]],
            "panes": [["paneID": "p", "contentRevision": revision, "rect": rect, "innerRect": rect,
                       "scroll": ["offset": offset, "maximum": 20, "rows": 1], "focused": true,
                       "mouseReporting": false, "pixelMouse": false, "alternateScreen": false, "pixelWidth": 0, "pixelHeight": 0]],
            "splits": [], "graphics": ["assets": [], "placements": [], "retained": []]]
        return try JSONDecoder().decode(HerdrEndpointSurface.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testImplicitNativeLinkCapturesRevisionWithoutSendingItsURL() throws {
        let surface = try linkSurface(url: "")
        let link = try XCTUnwrap(EndpointPluginLinkInvocation.capture(in: surface, column: 1, row: 0,
                                                                     expectedURL: "https://example.com"))
        XCTAssertEqual(link.explicit, false)
        XCTAssertNoThrow(try link.validate(in: surface))
        XCTAssertNil(link.params["url"])
        XCTAssertThrowsError(try link.validate(in: linkSurface(revision: 3, url: "")))
        XCTAssertThrowsError(try link.validate(in: linkSurface(offset: 1, url: "")))
        XCTAssertThrowsError(try link.validate(in: linkSurface(url: "https://example.com")))
        XCTAssertNil(EndpointPluginLinkInvocation.capture(in: try linkSurface(), column: 1, row: 0,
                                                          expectedURL: "https://example.com"))
        XCTAssertNil(EndpointPluginLinkInvocation.capture(in: surface, column: 1, row: 0, expectedURL: "bad\nlink"))
        XCTAssertEqual(try JSONDecoder().decode(EndpointPluginLinkInvocation.self, from: JSONEncoder().encode(link)), link)
    }

    func testPluginLinkCapturesPaneCoordinatesAndRejectsStaleContent() throws {
        let surface = try linkSurface()
        let links = EndpointPluginLinkInvocation.links(in: surface)
        XCTAssertEqual(links.count, 1)
        let link = try XCTUnwrap(links.first)
        XCTAssertEqual(link.column, 0)
        XCTAssertEqual(link.row, 0)
        XCTAssertEqual(link.params["content_revision"], .number(2))
        XCTAssertEqual(link.params["offset_from_bottom"], .number(0))
        XCTAssertNil(link.params["url"])
        XCTAssertNoThrow(try link.validate(in: surface))
        XCTAssertThrowsError(try link.validate(in: linkSurface(revision: 4)))
        XCTAssertThrowsError(try link.validate(in: linkSurface(offset: 1)))
        XCTAssertThrowsError(try link.validate(in: linkSurface(url: "plugin://changed")))
        XCTAssertEqual(EndpointPluginLinkInvocation.capture(in: surface, column: 1, row: 0), link)
        XCTAssertNil(EndpointPluginLinkInvocation.capture(in: surface, column: 0, row: 0))
        XCTAssertNil(EndpointPluginLinkInvocation.capture(in: surface, column: 3, row: 0))
        XCTAssertTrue(EndpointPluginLinkInvocation.links(in: try linkSurface(url: "bad\nlink")).isEmpty)
    }
}
