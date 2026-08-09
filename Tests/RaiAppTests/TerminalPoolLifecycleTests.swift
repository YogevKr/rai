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

    /// The pool sizes itself to the herd, so a herd bigger than the old fixed
    /// bound of 8 keeps every pane resident instead of evicting and re-spawning
    /// an attach on each visit.
    func testPoolGrowsToTheHerdSizeBetweenItsFloorAndCeiling() {
        let pool = TerminalPool(socketPath: socket)
        defer { pool.removeAll() }

        pool.retain(terminalIDs: Set((0..<3).map { "term-\($0)" }))
        XCTAssertEqual(pool.poolStateForTesting.capacity, TerminalPool.minimumCapacity)

        pool.retain(terminalIDs: Set((0..<15).map { "term-\($0)" }))
        XCTAssertEqual(pool.poolStateForTesting.capacity, 15)

        pool.retain(terminalIDs: Set((0..<80).map { "term-\($0)" }))
        XCTAssertEqual(pool.poolStateForTesting.capacity, TerminalPool.maximumCapacity)
    }

    /// A shrinking herd must not strand live terminals. Re-bounding the tracker
    /// before reaping the dead spent the smaller capacity on terminals that were
    /// already gone and surrendered LIVE keys instead — their entries stayed
    /// pooled but untracked, and an untracked entry can never be evicted.
    func testShrinkingHerdLeavesNoUntrackedTerminals() {
        let pool = TerminalPool(socketPath: socket)
        defer { pool.removeAll() }

        let big = (0..<12).map { "term-\($0)" }
        pool.retain(terminalIDs: Set(big))
        for terminalID in big {
            _ = pool.view(for: terminalID)
        }
        XCTAssertEqual(pool.poolStateForTesting.pooled.count, big.count)

        let survivors = Set(big.prefix(3))
        pool.retain(terminalIDs: survivors)

        let state = pool.poolStateForTesting
        XCTAssertEqual(state.pooled, survivors)
        XCTAssertEqual(
            state.pooled,
            state.tracked,
            "every pooled terminal must stay in the LRU tracker"
        )
    }

    /// Before the first snapshot lands there is no live set to check against,
    /// so the pool must still serve the panes it is asked for.
    func testUnknownTerminalIsServedBeforeAnySnapshot() {
        let pool = TerminalPool(socketPath: socket)
        defer { pool.removeAll() }

        XCTAssertNotNil(pool.view(for: "term-first"))
    }
}
