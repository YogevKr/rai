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
        let client = ClientInfo(
            deviceID: "phone-1",
            name: "Yogev’s iPhone",
            platform: "iOS",
            model: "iPhone"
        )
        let messages: [BridgeMessage] = [
            .pair(
                code: "23456789",
                protocolVersion: bridgeProtocolVersion,
                client: client
            ),
            .hello(token: "pair-token", client: client),
            .subscribe,
            .attachStream(paneID: "pane-1", cols: 80, rows: 24, fullGrid: false),
            .attachStream(paneID: "pane-1", cols: 80, rows: 24, fullGrid: true),
            .detachStream(paneID: "pane-1"),
            .input(paneID: "pane-1", bytesBase64: bytes),
            .sendImage(paneID: "pane-1", bytesBase64: bytes, filename: "photo.png"),
            .focusPane(paneID: "pane-1"),
            .selectPane(paneID: "pane-1"),
            .resizePane(paneID: "pane-1", cols: 120, rows: 40),
            .launchAgent(workspaceID: nil, agent: "claude", cwd: nil),
            .launchAgent(workspaceID: "workspace-1", agent: "codex", cwd: "/tmp/repo"),
            .renamePane(paneID: "pane-1", label: "API"),
            .renameTab(tabID: "tab-1", label: "Backend"),
            .closePane(paneID: "pane-1"),
            .closeTab(tabID: "tab-1"),
            .registerPush(deviceToken: "012345abcdef", environment: "sandbox"),
            .unregisterPush(deviceToken: "012345abcdef"),
            .readScrollback(paneID: "pane-1", lines: 600, rows: 39, fullGrid: false),
            .readScrollback(paneID: "pane-1", lines: 600, rows: 39, fullGrid: true),
            .sendKeys(paneID: "pane-1", keys: ["1"]),
            .pushPrefs(PushPreferences(
                kinds: .init(needsYou: true, finished: false),
                snoozeUntil: Date(timeIntervalSinceReferenceDate: 1_000),
                dnd: .init(start: 22 * 60, end: 8 * 60)
            )),
            .paired(
                token: "device-token",
                protocolVersion: bridgeProtocolVersion,
                sessionName: "default"
            ),
            .welcome(protocolVersion: bridgeProtocolVersion, sessionName: "default"),
            .welcome(protocolVersion: bridgeProtocolVersion, sessionName: nil),
            .authFailed(
                reason: "Invalid pairing token",
                code: .repairRequired,
                detail: "Credential not found"
            ),
            .snapshot(snapshot),
            .event(BridgeEvent(
                name: "layout.updated",
                payload: ["tab_id": .string("tab-1")]
            )),
            .paneFrame(
                paneID: "pane-1", bytesBase64: bytes, full: true, seq: 1,
                cols: nil, rows: nil),
            .paneFrame(
                paneID: "pane-1", bytesBase64: bytes, full: true, seq: 1,
                cols: 80, rows: 29),
            .scrollback(paneID: "pane-1", bytesBase64: bytes),
            .pushPrefsState(.default),
            .error(
                message: "Herdr is unavailable",
                code: .herdMissing,
                detail: "No snapshot"
            ),
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

    // A message from an OLD peer (no full_grid / frame dimension keys)
    // must decode with the compatibility defaults, not fail.
    func testLegacyMessagesWithoutNewKeysDecode() throws {
        let attach = Data(
            """
            {"type":"attachStream","paneID":"pane-1","cols":80,"rows":24}
            """.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(BridgeMessage.self, from: attach),
            .attachStream(paneID: "pane-1", cols: 80, rows: 24, fullGrid: false)
        )
        let frame = Data(
            """
            {"type":"paneFrame","paneID":"pane-1","bytesBase64":"AA==","full":true,"seq":7}
            """.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(BridgeMessage.self, from: frame),
            .paneFrame(
                paneID: "pane-1", bytesBase64: "AA==", full: true, seq: 7,
                cols: nil, rows: nil)
        )
        let scrollback = Data(
            """
            {"type":"readScrollback","paneID":"pane-1","lines":600,"rows":39}
            """.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(BridgeMessage.self, from: scrollback),
            .readScrollback(paneID: "pane-1", lines: 600, rows: 39, fullGrid: false)
        )
        let error = Data(#"{"type":"error","message":"Old Mac prose"}"#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(BridgeMessage.self, from: error),
            .error(message: "Old Mac prose", code: nil, detail: nil)
        )
        let auth = Data(#"{"type":"authFailed","reason":"Old reason"}"#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(BridgeMessage.self, from: auth),
            .authFailed(reason: "Old reason", code: nil, detail: nil)
        )
        let future = Data(
            #"{"type":"error","message":"Future prose","code":"future_code","detail":"More"}"#.utf8
        )
        XCTAssertEqual(
            try JSONDecoder().decode(BridgeMessage.self, from: future),
            .error(message: "Future prose", code: nil, detail: "More")
        )
        let preferences = Data(
            #"{"type":"pushPrefs","kinds":{"needsYou":true,"finished":true},"dnd":{"start":1320,"end":480}}"#.utf8
        )
        XCTAssertEqual(
            try JSONDecoder().decode(BridgeMessage.self, from: preferences),
            .pushPrefs(.init(dnd: .init(start: 1_320, end: 480)))
        )
    }

    func testBridgeProtocolVersionIsSix() {
        XCTAssertEqual(bridgeProtocolVersion, 6)
    }

    func testSnapshotPaneDecodesAdditiveBeaconAndUnknownFields() throws {
        let data = Data(
            """
            {
              "type":"snapshot",
              "snapshot":{
                "version":"0.1","protocol":16,
                "focused_workspace_id":null,"focused_tab_id":null,
                "focused_pane_id":"w1:p1","workspaces":[],"tabs":[],
                "panes":[{
                  "pane_id":"w1:p1","terminal_id":"term-1",
                  "workspace_id":"w1","tab_id":"w1:t1","focused":true,
                  "cwd":"/repo","agent":"claude","agent_status":"blocked",
                  "revision":1,"future_phone_field":{"safe":true},
                  "beacon":{
                    "event":"PermissionRequest","pane_id":"w1:p1",
                    "session_id":"session-1","cwd":"/repo",
                    "transcript_path":"/tmp/session.jsonl","tool_name":"Bash",
                    "tool_input":{"command":"swift test"},"ts":1780000000
                  }
                }],
                "layouts":[]
              }
            }
            """.utf8
        )

        guard case let .snapshot(snapshot) = try JSONDecoder().decode(
            BridgeMessage.self,
            from: data
        ) else {
            return XCTFail("Expected snapshot")
        }
        XCTAssertEqual(snapshot.panes.first?.beacon?.pendingSummary, "Bash: swift test")
    }

    // Additive-only messages (workspace ops, broadcast, sessions, background
    // work) round-trip and stay valid JSON — old clients skip unknown types.
    func testParityBatchMessagesRoundTrip() throws {
        let messages: [BridgeMessage] = [
            .renameWorkspace(workspaceID: "w7", label: "renamed"),
            .closeWorkspace(workspaceID: "w7"),
            .broadcastInput(tabID: "w7:t1", text: "git status"),
            .listSessions,
            .selectSession(name: "default"),
            .pushPrefs(.default),
            .pushPrefsState(.default),
            .backgroundWork([
                PaneBackgroundWork(
                    paneID: "w7:p1",
                    summaries: ["[monitor] merge-queue watch", "[subagent] Audit iOS app"]
                ),
            ]),
            .sessions([
                BridgeSessionInfo(name: "default", isRunning: true, isCurrent: true),
                BridgeSessionInfo(name: "lab", isRunning: false, isCurrent: false),
            ]),
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for message in messages {
            let encoded = try encoder.encode(message)
            XCTAssertEqual(
                try decoder.decode(BridgeMessage.self, from: encoded),
                message
            )
        }
    }
}
