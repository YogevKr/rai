import Foundation
import RaiCore
import XCTest
@testable import RaiApp

@MainActor
final class EndpointHistoryBridgeTests: XCTestCase {
    func testPhoneHistoryRefreshesTwiceWithoutDisconnectingItsView() async throws {
        let root = URL(fileURLWithPath: "/tmp/rai-history-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let api = root.appendingPathComponent("herdr.sock").path
        let endpoint = RemoteConnection.clientSocketPath(for: api)
        let record = root.appendingPathComponent("requests").path
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("RaiCoreTests/Fixtures/fake_endpoint_server.py")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, endpoint, "history_race", record]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let ready = expectation(description: "phone view ready")
        let completed = expectation(description: "phone history completed")
        let identity = EndpointViewIdentity(connectionID: "isolated-host")
        var latest: EndpointBridgeState?
        var announced = false, finished = false
        let host = EndpointBridgeHost(identity: identity, socketPath: api) { state, done in
            latest = state
            if state.surface != nil, !state.busy, !announced { announced = true; ready.fulfill() }
            if state.terminalResult != nil, !state.busy, !finished { finished = true; completed.fulfill() }
            done()
        }
        defer {
            host.stop()
            if process.isRunning { process.terminate() }
            try? FileManager.default.removeItem(at: root)
        }
        try process.run()
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: endpoint) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        host.handle(.init(identity: identity, sequence: 1, operation: .open(columns: 80, rows: 24)))
        await fulfillment(of: [ready], timeout: 5)
        XCTAssertNil(latest?.error)
        let request = EndpointTextRequest(bootID: "boot", paneID: "phone",
            action: .history(startRow: 0, endRow: 0, endColumn: 0, revision: 2, truncated: false))
        host.handle(.init(identity: identity, sequence: 2, bootID: "boot", operation: .terminalAction(request)))
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(latest?.terminalResult?.requestID, request.id)
        XCTAssertEqual(latest?.terminalResult?.text, "stable phone history 👩🏽‍💻")
        XCTAssertNil(latest?.terminalResult?.error)
        XCTAssertNil(latest?.error)
        XCTAssertEqual(latest?.snapshot?.bootID, "boot")
        let calls = try String(contentsOfFile: record + ".history").split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls.compactMap { ($0["params"] as? [String: Any])?["content_revision"] as? Int }, [4, 6, 6])
        XCTAssertEqual(calls.compactMap { $0["method"] as? String }, ["pane.copy_motion", "pane.copy_motion", "pane.selection.read"])
        host.handle(.init(identity: identity, sequence: 3, bootID: "boot", operation: .resize(columns: 79, rows: 24)))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(latest?.sequence, 3)
        XCTAssertNil(latest?.error)
        XCTAssertNotNil(latest?.snapshot)
    }
}
