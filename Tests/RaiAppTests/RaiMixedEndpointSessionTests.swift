import AppKit
import Combine
import RaiCore
import XCTest
@testable import RaiApp

@MainActor
final class RaiMixedEndpointSessionTests: XCTestCase {
    private let socket = "/nonexistent/rai-mixed-tests.sock"

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    func testStopEvictsOwnedPoolAndRejectsLateViewUpdates() throws {
        let session = RaiMixedEndpointSession(endpoint: .init(session: "test"), connectionID: "test",
                                              socketPath: socket, attachExecutable: "/usr/bin/true")
        let pool = session.pool
        let view = try XCTUnwrap(pool.view(for: "terminal"))
        session.stop()
        XCTAssertTrue(pool.poolStateForTesting.pooled.isEmpty)
        XCTAssertNil(pool.view(for: "terminal"))
        XCTAssertNil(view.superview)
        session.start()
        XCTAssertNil(pool.view(for: "terminal"), "A stopped session must be replaced, not restarted.")
    }

    func testStopPreservesBorrowedPrimaryPool() throws {
        let pool = TerminalPool(socketPath: socket, attachExecutable: "/usr/bin/true")
        defer { pool.removeAll() }
        let view = try XCTUnwrap(pool.view(for: "terminal"))
        let session = RaiMixedEndpointSession(endpoint: .init(session: "test"), connectionID: "test",
                                              socketPath: socket, sharedTerminalPool: pool)
        session.stop()
        XCTAssertTrue(pool.view(for: "terminal") === view)
    }

    func testEndpointFailureStopsOwnedPoolAndRemainsFailed() async throws {
        let session = RaiMixedEndpointSession(endpoint: .init(session: "test"), connectionID: "test",
                                              socketPath: socket, attachExecutable: "/usr/bin/true")
        defer { session.stop() }
        _ = try XCTUnwrap(session.pool.view(for: "terminal"))
        let failed = expectation(description: "Endpoint failure")
        let observation = session.$error.compactMap { $0 }.first().sink { _ in failed.fulfill() }
        defer { observation.cancel() }
        session.start()
        await fulfillment(of: [failed], timeout: 3)
        XCTAssertTrue(session.hasError)
        XCTAssertNil(session.snapshot)
        XCTAssertTrue(session.pool.poolStateForTesting.pooled.isEmpty)
        XCTAssertNil(session.pool.view(for: "terminal"))
        session.start()
        XCTAssertTrue(session.hasError)
    }

    func testAttachmentRequiresMatchingClientAndPrefersArchive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("herdr")
        try Data("#!/bin/sh\nprintf '%s' '{\"protocol\":22}'\n".utf8).write(to: local)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: local.path)
        let archive = HerdrClientArchive(directory: root.appendingPathComponent("archive"))
        let matched = try await RaiMixedEndpointSession.attachExecutable(for: 22, localExecutable: local.path, archive: archive)
        XCTAssertEqual(matched, local.path)
        do {
            _ = try await RaiMixedEndpointSession.attachExecutable(for: 23, localExecutable: local.path, archive: archive)
            XCTFail("A mismatched installed client must not attach.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("protocol 23"))
        }
        let retained = try await archive.retain(source: local, protocolVersion: 22) { _ in 22 }
        let archived = try await RaiMixedEndpointSession.attachExecutable(for: 22, localExecutable: nil, archive: archive)
        XCTAssertEqual(archived, retained.path)
    }

    func testTerminalIDRefreshOnlyFollowsPaneSetChanges() throws {
        let snapshot = try JSONDecoder().decode(HerdrEndpointSnapshot.self, from: Data(
            #"{"boot_id":"boot","revision":2,"panes":[{"pane_id":"p1"}]}"#.utf8
        ))
        XCTAssertFalse(
            RaiMixedEndpointSession.needsTerminalIDRefresh(
                snapshot, terminalIDs: ["p1": "term-1"], hasSnapshot: true
            )
        )
        XCTAssertFalse(
            RaiMixedEndpointSession.needsTerminalIDRefresh(
                snapshot, terminalIDs: ["p1": "term-1", "p2": "term-2"], hasSnapshot: true
            )
        )
        XCTAssertTrue(
            RaiMixedEndpointSession.needsTerminalIDRefresh(
                snapshot, terminalIDs: ["p2": "term-2"], hasSnapshot: true
            )
        )
        XCTAssertTrue(
            RaiMixedEndpointSession.needsTerminalIDRefresh(
                snapshot, terminalIDs: [:], hasSnapshot: false
            )
        )
    }
}
