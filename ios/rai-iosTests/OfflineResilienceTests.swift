import Foundation
import Network
import RaiCore
import XCTest

@testable import rai

final class OfflineResilienceTests: XCTestCase {
    func testSnapshotCacheRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rai-offline-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("snapshot.json")
        let store = SnapshotCacheStore(fileURL: fileURL)
        let cached = CachedHerdSnapshot(
            snapshot: try snapshot(paneCount: 1),
            savedAt: Date(timeIntervalSince1970: 1_788_361_500),
            pairingID: "pairing-id"
        )

        let saved = expectation(description: "snapshot saved")
        store.save(cached) { result in
            if case let .failure(error) = result {
                XCTFail("Snapshot save failed: \(error)")
            }
            saved.fulfill()
        }
        wait(for: [saved], timeout: 2)

        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.savedAt, cached.savedAt)
        XCTAssertEqual(loaded.pairingID, cached.pairingID)
        XCTAssertEqual(loaded.snapshot.panes.first?.cwd, "rai")
        XCTAssertNil(loaded.snapshot.panes.first?.agentSession)
        XCTAssertNil(loaded.snapshot.panes.first?.foregroundCWD)
        XCTAssertNil(loaded.snapshot.panes.first?.terminalTitle)
        XCTAssertNil(loaded.snapshot.workspaces.first?.worktree)
        XCTAssertEqual(
            try fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
                .isExcludedFromBackup,
            true
        )

        let cleared = expectation(description: "snapshot cleared")
        store.clear {
            cleared.fulfill()
        }
        wait(for: [cleared], timeout: 2)

        XCTAssertNil(store.load())
    }

    func testSnapshotCacheWriteRunsOffMainAndClearWins() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rai-offline-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = DispatchQueue(label: "rai.snapshot-cache.tests")
        queue.suspend()
        let store = SnapshotCacheStore(
            fileURL: directory.appendingPathComponent("snapshot.json"),
            queue: queue
        )
        let cached = CachedHerdSnapshot(
            snapshot: try snapshot(paneCount: 1),
            savedAt: Date(timeIntervalSince1970: 1_788_361_500),
            pairingID: "pairing-id"
        )
        let saved = expectation(description: "snapshot saved off main")
        let cleared = expectation(description: "pending snapshot cleared")

        store.save(cached) { result in
            XCTAssertFalse(Thread.isMainThread)
            if case let .failure(error) = result {
                XCTFail("Snapshot save failed: \(error)")
            }
            saved.fulfill()
        }
        store.clear {
            XCTAssertFalse(Thread.isMainThread)
            cleared.fulfill()
        }
        queue.resume()

        wait(for: [saved, cleared], timeout: 2, enforceOrder: true)
        XCTAssertNil(store.load())
    }

    func testFreshnessStamps() {
        let timeZone = TimeZone(secondsFromGMT: 0)!
        let seen = Date(timeIntervalSince1970: 1_788_357_900)

        XCTAssertEqual(
            SnapshotFreshness.lastSeen(at: seen, timeZone: timeZone),
            "last seen 14:05"
        )
        XCTAssertEqual(
            SnapshotFreshness.syncedAgo(
                since: seen,
                now: seen.addingTimeInterval(9)
            ),
            "synced 9s ago"
        )
        XCTAssertEqual(
            SnapshotFreshness.syncedAgo(
                since: seen,
                now: seen.addingTimeInterval(125)
            ),
            "synced 2m ago"
        )
    }

    @MainActor
    func testCachedSnapshotNeverShowsTheEmptyHerdState() throws {
        let connection = BridgeConnection()
        let empty = try snapshot(paneCount: 0)
        let pairing = try Pairing(host: "studio.local", port: 9_876, token: "secret")
        connection.restoreCachedSnapshot(
            CachedHerdSnapshot(
                snapshot: empty,
                savedAt: Date(),
                pairingID: CachedHerdSnapshot.pairingID(for: pairing)
            )
        )

        XCTAssertNotNil(connection.snapshot)
        XCTAssertTrue(connection.isShowingCachedSnapshot)
        XCTAssertFalse(connection.shouldShowEmptyHerd)

        connection.replaceWithLiveSnapshot(empty)

        XCTAssertFalse(connection.isShowingCachedSnapshot)
        XCTAssertTrue(connection.shouldShowEmptyHerd)
    }

    func testCachedSnapshotIsBoundToItsPairing() throws {
        let first = try Pairing(host: "studio.local", port: 9_876, token: "first")
        let second = try Pairing(host: "studio.local", port: 9_876, token: "second")
        let cached = CachedHerdSnapshot(
            snapshot: try snapshot(paneCount: 1),
            savedAt: Date(),
            pairingID: CachedHerdSnapshot.pairingID(for: first)
        )

        XCTAssertTrue(cached.belongs(to: first))
        XCTAssertFalse(cached.belongs(to: second))
    }

    func testURLDiagnosisMapping() {
        assertDiagnosis(
            URLError(.cannotFindHost),
            message: "Can't find studio.local on this network"
        )
        assertDiagnosis(
            URLError(.cannotConnectToHost),
            message: "Rai on the Mac isn't listening — is Rai running with the bridge on?"
        )
        assertDiagnosis(
            URLError(.networkConnectionLost),
            message: "Connection to studio.local was lost"
        )
        assertDiagnosis(
            URLError(.timedOut),
            message: "No route to the Mac — same Wi-Fi, or Tailscale on?"
        )
        assertDiagnosis(
            URLError(.secureConnectionFailed),
            message: "TLS failed — check Tailscale Serve on the Mac"
        )
    }

    func testNetworkDiagnosisMapping() {
        assertDiagnosis(
            NWError.posix(.ECONNREFUSED),
            message: "Rai on the Mac isn't listening — is Rai running with the bridge on?"
        )
        assertDiagnosis(
            NWError.posix(.ECONNRESET),
            message: "Rai on the Mac isn't listening — is Rai running with the bridge on?"
        )
        assertDiagnosis(
            NWError.posix(.EPIPE),
            message: "Connection to studio.local was lost"
        )
        assertDiagnosis(
            NWError.posix(.EHOSTUNREACH),
            message: "No route to the Mac — same Wi-Fi, or Tailscale on?"
        )
        assertDiagnosis(
            NWError.dns(-65_538),
            message: "Can't find studio.local on this network"
        )
        assertDiagnosis(
            NWError.tls(-9_806),
            message: "TLS failed — check Tailscale Serve on the Mac"
        )
    }

    func testHelloRejectionAndMissingHerdDiagnosis() {
        let rejected = ConnectionDiagnosis.helloRejected(reason: "Invalid token")
        XCTAssertEqual(rejected.message, "Pairing was rejected by the Mac")
        XCTAssertEqual(rejected.rawDetails, "Invalid token")
        XCTAssertEqual(rejected.action, .pairAgain)

        let mismatch = ConnectionDiagnosis.protocolMismatch(99)
        XCTAssertEqual(
            mismatch.message,
            "Rai versions don't match — update Rai on the Mac or iPhone"
        )
        XCTAssertEqual(mismatch.action, .reconnect)

        let missing = ConnectionDiagnosis.bridgeError(
            "Herdr is not connected.",
            host: "studio.local"
        )
        XCTAssertEqual(missing.message, "herdr isn't running on the Mac")
        XCTAssertEqual(missing.rawDetails, "Herdr is not connected.")
        XCTAssertEqual(missing.action, .reconnect)
    }

    private func assertDiagnosis(
        _ error: Error,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let diagnosis = ConnectionDiagnosis.transport(error, host: "studio.local")
        XCTAssertEqual(diagnosis.message, message, file: file, line: line)
        XCTAssertEqual(diagnosis.action, .reconnect, file: file, line: line)
        XCTAssertFalse(diagnosis.rawDetails.isEmpty, file: file, line: line)
    }

    private func snapshot(paneCount: Int) throws -> SessionSnapshot {
        let paneJSON = paneCount == 0 ? "" :
            """
            {
              "pane_id":"w1:p1","terminal_id":"term-1","workspace_id":"w1",
              "tab_id":"w1:t1","focused":true,"cwd":"/repo/rai",
              "foreground_cwd":"/repo/rai/Sources",
              "agent":"claude","agent_status":"working","revision":2,
              "terminal_title":"secret prompt","terminal_title_stripped":"Claude",
              "agent_session":{"agent":"claude","kind":"id",
                "source":"herdr:claude","value":"resume-secret"}
            }
            """
        let workspaceJSON = paneCount == 0 ? "" :
            """
            {
              "workspace_id":"w1","number":1,"label":"rai","focused":true,
              "pane_count":1,"tab_count":1,"active_tab_id":"w1:t1",
              "agent_status":"working",
              "worktree":{"repo_key":"/Users/yogev/repos/rai/.git",
                "repo_name":"rai","repo_root":"/Users/yogev/repos/rai",
                "checkout_path":"/Users/yogev/repos/rai/worktree",
                "is_linked_worktree":true}
            }
            """
        let tabJSON = paneCount == 0 ? "" :
            """
            {
              "tab_id":"w1:t1","workspace_id":"w1","number":1,"label":"rai",
              "focused":true,"pane_count":1,"agent_status":"working"
            }
            """
        let json = """
        {
          "version":"0.7.5","protocol":16,
          "focused_workspace_id":null,"focused_tab_id":null,"focused_pane_id":null,
          "workspaces":[\(workspaceJSON)],
          "tabs":[\(tabJSON)],
          "panes":[\(paneJSON)],
          "layouts":[]
        }
        """
        return try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
    }
}
