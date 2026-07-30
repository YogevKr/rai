import AppKit
import XCTest

@testable import RaiApp

/// Closing a pane evicts its terminal, but SwiftUI still updates that pane's
/// container once on its way out. The pool used to answer that update by
/// re-creating the entry and spawning a fresh `herdr terminal attach` for a
/// terminal herdr had already destroyed, which then retried its way to nothing.
@MainActor
final class TerminalPoolLifecycleTests: XCTestCase {
    private let socket = "/nonexistent/rai-tests-herd.sock"

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    func testClosedTerminalIsNotResurrected() {
        let pool = TerminalPool(socketPath: socket)
        defer { pool.removeAll() }

        pool.retain(terminalIDs: ["term-live"])

        XCTAssertNil(pool.view(for: "term-closed"))
    }

    func testTerminalHerdrStillReportsIsStillCreated() {
        let pool = TerminalPool(socketPath: socket)
        defer { pool.removeAll() }

        pool.retain(terminalIDs: ["term-live"])

        XCTAssertNotNil(pool.view(for: "term-live"))
    }

    /// Before the first snapshot lands there is no live set to check against,
    /// so the pool must still serve the panes it is asked for.
    func testUnknownTerminalIsServedBeforeAnySnapshot() {
        let pool = TerminalPool(socketPath: socket)
        defer { pool.removeAll() }

        XCTAssertNotNil(pool.view(for: "term-first"))
    }
}
