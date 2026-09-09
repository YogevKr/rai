import XCTest
import RaiCore
@testable import RaiApp

final class EndpointPluginAuditTests: XCTestCase {
    func testPluginPaneAuditKeepsTargetIdentifiersWithoutPluginCommands() throws {
        let snapshot = try JSONDecoder().decode(HerdrEndpointSnapshot.self, from: Data(
            #"{"boot_id":"boot","revision":1,"focused_pane_id":"p1"}"#.utf8))
        let installed = try XCTUnwrap(EndpointInstalledPlugin(.object(["plugin_id": .string("plugin"), "name": .string("Plugin"),
            "enabled": .bool(true), "panes": .array([.object(["id": .string("popup"), "command": .array([.string("secret-command")])])])])))
        let invocation = try XCTUnwrap(EndpointPluginPaneInvocation(plugin: installed,
            pane: try XCTUnwrap(installed.panes.first), snapshot: snapshot))
        let request = EndpointBridgeRequest(identity: .init(connectionID: "connection"), sequence: 1, bootID: "boot",
            operation: .plugin(.init(bootID: "boot", operation: .openPane(invocation))))
        let event = try XCTUnwrap(BridgeAuditEvent(.endpointRequest(request)))
        XCTAssertEqual(event.action, "endpoint.plugin.pane.open")
        XCTAssertEqual(event.targetIDs["plugin_id"], "plugin")
        XCTAssertEqual(event.targetIDs["entrypoint"], "popup")
        XCTAssertEqual(event.targetIDs["pane_id"], "p1")
        XCTAssertFalse(event.targetIDs.values.contains("secret-command"))
    }

    func testInstallAuditOmitsSourceReferenceAndPluginCode() throws {
        let plugin = EndpointPluginRequest(bootID: "boot", operation: .prepareInstall(source: "private-source", reference: "private-reference"))
        let request = EndpointBridgeRequest(identity: .init(connectionID: "connection"), sequence: 1,
                                            bootID: "boot", operation: .plugin(plugin))
        let event = try XCTUnwrap(BridgeAuditEvent(.endpointRequest(request)))
        XCTAssertEqual(event.action, "endpoint.plugin.install.review")
        XCTAssertEqual(event.targetIDs["request_id"], request.requestID)
        XCTAssertEqual(event.targetIDs["plugin_request_id"], plugin.id.uuidString)
        XCTAssertFalse(event.targetIDs.values.contains("private-source"))
        XCTAssertFalse(event.targetIDs.values.contains("private-reference"))
        XCTAssertEqual(event.content, .none)
    }
}
