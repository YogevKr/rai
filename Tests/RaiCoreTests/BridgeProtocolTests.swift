import RaiCore
import XCTest

final class BridgeProtocolTests: XCTestCase {
    func testEveryBridgeMessageRoundTrips() throws {
        let snapshotJSON = """
        {
          "version":"0.1","protocol":16,
          "focused_workspace_id":null,"focused_tab_id":null,"focused_pane_id":null,
          "workspaces":[],"tabs":[],"panes":[],"layouts":[]
        }
        """
        let snapshot = try JSONDecoder().decode(
            SessionSnapshot.self,
            from: Data(snapshotJSON.utf8)
        )
        let bytes = Data([0x00, 0x1B, 0xFF]).base64EncodedString()
        let client = ClientInfo(deviceID: "phone-1", name: "Yogev’s iPhone", platform: "iOS")
        let messages: [BridgeMessage] = [
            .hello(token: "pair-token", client: client),
            .subscribe,
            .requestPane(paneID: "pane-1"),
            .input(paneID: "pane-1", bytesBase64: bytes),
            .focusPane(paneID: "pane-1"),
            .selectPane(paneID: "pane-1"),
            .resizePane(paneID: "pane-1", cols: 120, rows: 40),
            .welcome(protocolVersion: bridgeProtocolVersion, sessionName: "default"),
            .welcome(protocolVersion: bridgeProtocolVersion, sessionName: nil),
            .authFailed(reason: "Invalid pairing token"),
            .snapshot(snapshot),
            .event(BridgeEvent(
                name: "layout.updated",
                payload: ["tab_id": .string("tab-1")]
            )),
            .paneOutput(paneID: "pane-1", bytesBase64: bytes),
            .error(message: "Herdr is unavailable"),
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for message in messages {
            let encoded = try encoder.encode(message)
            XCTAssertEqual(
                try decoder.decode(BridgeMessage.self, from: encoded),
                message
            )
            XCTAssertNotNil(
                try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            )
        }
    }
}
