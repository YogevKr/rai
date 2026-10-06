import AppKit
import Foundation
import RaiCore
import Security
import XCTest

@testable import RaiApp

@MainActor
final class RaiBridgeServerHistoryTests: XCTestCase {
    func testScrollbackUsesRPCSourceAndPreservesHistoryBeforeTheVisibleGrid() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/rai-scrollback-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let socket = root.appendingPathComponent("herdr.sock")
        let defaultsName = "RaiBridgeServerHistoryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("RaiCoreTests/Fixtures/fake_scrollback_server.py").path,
            socket.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        defer {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: root)
        }
        try process.run()
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: socket.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket.path))
        let model = RaiModel(client: HerdrClient(socketPath: socket.path), userDefaults: defaults)
        let server = RaiBridgeServer(
            model: model, userDefaults: defaults,
            apnsSettings: APNsSettings(
                defaults: defaults,
                keyFileURL: root.appendingPathComponent("unused-key.p8"),
                keyReader: { ("", errSecItemNotFound) }
            ),
            auditLogURL: root.appendingPathComponent("audit.jsonl")
        )
        let payload = await server.readScrollbackPayload(paneID: "w1:p1", lines: 100, clientRows: nil)
        XCTAssertEqual(payload.map { String(decoding: $0, as: UTF8.self) }, "older output\n\u{1B}[0m")
    }

    func testPaneObservationReconnectsWhileTheHostSnapshotLoads() {
        let error = RaiBridgeServer.paneAvailabilityError(paneID: "w1:p1", snapshot: nil)
        guard case let .error(_, code, _, _, _) = error else {
            return XCTFail("Expected a reconnectable host error")
        }
        XCTAssertEqual(code, .herdMissing)
    }

    func testPaneObservationReportsOnlyPanesAbsentFromALiveSnapshot() throws {
        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data("""
        {"version":"1","protocol":22,"workspaces":[],"tabs":[],"layouts":[],
         "panes":[{"pane_id":"w1:p1","terminal_id":"term-1","workspace_id":"w1",
                   "tab_id":"w1:t1","focused":true,"cwd":"/tmp","agent_status":"idle","revision":1}]}
        """.utf8))
        XCTAssertNil(RaiBridgeServer.paneAvailabilityError(paneID: "w1:p1", snapshot: snapshot))
        let error = RaiBridgeServer.paneAvailabilityError(paneID: "w1:p2", snapshot: snapshot)
        guard case let .error(_, code, _, _, _) = error else {
            return XCTFail("Expected a missing pane error")
        }
        XCTAssertEqual(code, .paneGone)
    }

    func testEmptyRequestKeepsBeaconSessionAsReplyIdentity() {
        let base = TranscriptHistoryPage(
            paneID: "pane",
            sessionID: "",
            resolvedSessionID: "beacon-session",
            requestID: "request",
            turns: [],
            hasMore: false
        )

        let reply = RaiBridgeServer.historyPage(
            base,
            requestedSessionID: "",
            requestID: "request",
            sinceLastSeen: nil
        )

        XCTAssertEqual(reply.sessionID, "")
        XCTAssertEqual(reply.resolvedSessionID, "beacon-session")
        XCTAssertEqual(reply.agentSessionID, "beacon-session")
    }
}
