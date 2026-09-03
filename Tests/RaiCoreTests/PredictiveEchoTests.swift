import XCTest

@testable import RaiCore

final class PredictiveEchoTests: XCTestCase {
    private var engine: PredictiveEchoEngine!
    private let start = Date(timeIntervalSinceReferenceDate: 1000)

    override func setUp() {
        super.setUp()
        engine = PredictiveEchoEngine()
    }

    private func type(
        _ text: String, cursorX: Int, row: Int = 5, columns: Int = 80, at time: Date? = nil
    ) {
        for (offset, character) in text.enumerated() {
            engine.noteKey(
                .printable(character),
                cursor: (x: cursorX + offset, y: row),
                columns: columns,
                alternateBufferActive: false,
                now: time ?? start
            )
        }
    }

    func testPredictionsQueueAtAdvancingColumns() {
        type("ls", cursorX: 10)
        XCTAssertEqual(engine.pending.map(\.character), ["l", "s"])
        XCTAssertEqual(engine.pending.map(\.column), [10, 11])
        XCTAssertEqual(engine.pending.map(\.row), [5, 5])
    }

    func testFastLinkNeverDisplays() {
        type("a", cursorX: 0)
        XCTAssertEqual(engine.displayGlyphs(now: start), [])
    }

    func testLocalThresholdDisplaysAfterMeasuredDaemonTick() {
        engine = PredictiveEchoEngine(herdLocation: .local)
        type("a", cursorX: 0)
        engine.reconcile(
            cursor: (x: 1, y: 5),
            alternateBufferActive: false,
            readCell: { column, _ in column == 0 ? "a" : nil },
            now: start.addingTimeInterval(0.020)
        )

        type("b", cursorX: 1, at: start.addingTimeInterval(0.021))
        XCTAssertEqual(engine.displayGlyphs(), ["b"])
    }

    func testRemoteThresholdDoesNotDisplayAfterLocalDaemonTick() {
        engine = PredictiveEchoEngine(herdLocation: .remote)
        type("a", cursorX: 0)
        engine.reconcile(
            cursor: (x: 1, y: 5),
            alternateBufferActive: false,
            readCell: { column, _ in column == 0 ? "a" : nil },
            now: start.addingTimeInterval(0.020)
        )

        type("b", cursorX: 1, at: start.addingTimeInterval(0.021))
        XCTAssertEqual(engine.displayGlyphs(), [])
    }

    func testNonEchoingPaneNeverDisplaysPrediction() {
        engine = PredictiveEchoEngine(herdLocation: .local)
        type("agent", cursorX: 0)

        for delay in [0.010, 0.050, 0.250, 1.0] {
            XCTAssertEqual(
                engine.displayGlyphs(now: start.addingTimeInterval(delay)),
                []
            )
        }
    }

    func testConfirmedPredictionVanishesOnReconcile() {
        engine = PredictiveEchoEngine(herdLocation: .local)
        type("a", cursorX: 0)
        engine.reconcile(
            cursor: (x: 1, y: 5),
            alternateBufferActive: false,
            readCell: { column, _ in column == 0 ? "a" : nil },
            now: start.addingTimeInterval(0.020)
        )
        type("b", cursorX: 1, at: start.addingTimeInterval(0.021))
        XCTAssertEqual(engine.displayGlyphs(), ["b"])

        engine.reconcile(
            cursor: (x: 2, y: 5),
            alternateBufferActive: false,
            readCell: { column, _ in column == 1 ? "b" : nil },
            now: start.addingTimeInterval(0.041)
        )
        XCTAssertEqual(engine.displayGlyphs(), [])
        XCTAssertTrue(engine.pending.isEmpty)
    }

    /// The password guard: after Enter, a hidden-input prompt (`sudo`,
    /// `read -s`) echoes nothing — no waiting period may ever paint the
    /// secret.
    func testHiddenInputNeverDisplays() {
        // Learn that the link is slow, with a confirmed echo.
        type("sudo", cursorX: 0)
        engine.reconcile(
            cursor: (x: 4, y: 5),
            alternateBufferActive: false,
            readCell: { column, _ in ["s", "u", "d", "o"][column] },
            now: start.addingTimeInterval(0.2)
        )
        XCTAssertGreaterThan(engine.smoothedConfirmLatency, 0.06)

        // Enter submits; the password prompt follows and echoes nothing.
        engine.noteKey(
            .other, cursor: (x: 4, y: 5), columns: 80,
            alternateBufferActive: false, now: start.addingTimeInterval(0.3)
        )
        let promptTime = start.addingTimeInterval(0.6)
        type("hunter2", cursorX: 10, row: 6, at: promptTime)
        for delay in [0.0, 0.1, 0.3, 1.0, 4.0] {
            XCTAssertEqual(
                engine.displayGlyphs(now: promptTime.addingTimeInterval(delay)), [],
                "secret visible after \(delay)s"
            )
        }
    }

    func testEchoStoppingMidBurstRetractsAndDropsConfidence() {
        type("a", cursorX: 0)
        engine.reconcile(
            cursor: (x: 1, y: 5),
            alternateBufferActive: false,
            readCell: { column, _ in column == 0 ? "a" : nil },
            now: start.addingTimeInterval(0.2)
        )
        // Echo goes silent mid-burst (program flipped echo off).
        let silent = start.addingTimeInterval(0.3)
        type("bc", cursorX: 1, at: silent)
        engine.reconcile(
            cursor: (x: 1, y: 5),
            alternateBufferActive: false,
            readCell: { _, _ in nil },
            now: silent.addingTimeInterval(0.6)
        )
        XCTAssertTrue(engine.pending.isEmpty)
        XCTAssertFalse(engine.echoConfirmedThisBurst)
    }

    func testDisplayResumesAfterConfirmInNewBurst() {
        type("a", cursorX: 0)
        engine.reconcile(
            cursor: (x: 1, y: 5),
            alternateBufferActive: false,
            readCell: { column, _ in column == 0 ? "a" : nil },
            now: start.addingTimeInterval(0.2)
        )
        engine.noteKey(
            .other, cursor: (x: 1, y: 5), columns: 80,
            alternateBufferActive: false, now: start.addingTimeInterval(0.3)
        )
        // New prompt, new burst: the first character displays nothing…
        let next = start.addingTimeInterval(0.5)
        type("l", cursorX: 0, row: 7, at: next)
        XCTAssertEqual(engine.displayGlyphs(now: next), [])
        // …until its echo confirms, which re-proves the prompt echoes.
        engine.reconcile(
            cursor: (x: 1, y: 7),
            alternateBufferActive: false,
            readCell: { column, _ in column == 0 ? "l" : nil },
            now: next.addingTimeInterval(0.2)
        )
        let after = next.addingTimeInterval(0.25)
        type("s", cursorX: 1, row: 7, at: after)
        XCTAssertEqual(engine.displayGlyphs(now: after), ["s"])
    }

    func testDisplayOpensImmediatelyOnceLatencyIsLearned() {
        type("a", cursorX: 0)
        // Echo confirms 200ms later: the engine learns the link is slow.
        engine.reconcile(
            cursor: (x: 1, y: 5),
            alternateBufferActive: false,
            readCell: { column, _ in column == 0 ? "a" : nil },
            now: start.addingTimeInterval(0.2)
        )
        XCTAssertTrue(engine.pending.isEmpty)
        XCTAssertGreaterThan(engine.smoothedConfirmLatency, 0.06)

        let next = start.addingTimeInterval(0.3)
        type("b", cursorX: 1, at: next)
        XCTAssertEqual(engine.displayGlyphs(now: next), ["b"])
    }

    func testExtraOutputFeedKeepsCurrentBurstConfidence() {
        type("a", cursorX: 0)
        engine.reconcile(
            cursor: (x: 1, y: 5),
            alternateBufferActive: false,
            readCell: { column, _ in column == 0 ? "a" : nil },
            now: start.addingTimeInterval(0.2)
        )
        XCTAssertTrue(engine.echoConfirmedThisBurst)

        // Shells can split one echo and its redraw controls across PTY feeds.
        engine.reconcile(
            cursor: (x: 1, y: 5),
            alternateBufferActive: false,
            readCell: { _, _ in nil },
            now: start.addingTimeInterval(0.21)
        )
        XCTAssertTrue(engine.echoConfirmedThisBurst)

        let next = start.addingTimeInterval(0.22)
        type("b", cursorX: 1, at: next)
        XCTAssertEqual(engine.displayGlyphs(now: next), ["b"])
    }

    func testConfirmsFromTheFrontAndKeepsTheRest() {
        type("cd ", cursorX: 3)
        engine.reconcile(
            cursor: (x: 4, y: 5),
            alternateBufferActive: false,
            readCell: { column, _ in column == 3 ? "c" : nil },
            now: start.addingTimeInterval(0.2)
        )
        XCTAssertEqual(engine.pending.map(\.character), ["d", " "])
    }

    func testContradictedCellClearsEverything() {
        type("ab", cursorX: 0)
        engine.reconcile(
            cursor: (x: 1, y: 5),
            alternateBufferActive: false,
            readCell: { _, _ in "x" },
            now: start.addingTimeInterval(0.2)
        )
        XCTAssertTrue(engine.pending.isEmpty)
    }

    func testRowChangeClears() {
        type("a", cursorX: 0)
        engine.reconcile(
            cursor: (x: 0, y: 6),
            alternateBufferActive: false,
            readCell: { _, _ in nil },
            now: start.addingTimeInterval(0.05)
        )
        XCTAssertTrue(engine.pending.isEmpty)
    }

    func testAlternateBufferSuppressesPredictions() {
        engine.noteKey(
            .printable("a"), cursor: (x: 0, y: 0), columns: 80,
            alternateBufferActive: true, now: start
        )
        XCTAssertTrue(engine.pending.isEmpty)

        type("a", cursorX: 0)
        engine.reconcile(
            cursor: (x: 0, y: 5),
            alternateBufferActive: true,
            readCell: { _, _ in nil },
            now: start
        )
        XCTAssertTrue(engine.pending.isEmpty)
    }

    func testBackspaceRetractsOnlyTheLastPrediction() {
        type("ab", cursorX: 0)
        engine.noteKey(
            .backspace, cursor: (x: 2, y: 5), columns: 80,
            alternateBufferActive: false, now: start
        )
        XCTAssertEqual(engine.pending.map(\.character), ["a"])

        engine.noteKey(
            .backspace, cursor: (x: 1, y: 5), columns: 80,
            alternateBufferActive: false, now: start
        )
        engine.noteKey(
            .backspace, cursor: (x: 0, y: 5), columns: 80,
            alternateBufferActive: false, now: start
        )
        XCTAssertTrue(engine.pending.isEmpty)
    }

    func testBackspaceWithEmptyQueueEndsTheBurst() {
        type("a", cursorX: 0)
        engine.reconcile(
            cursor: (x: 1, y: 5),
            alternateBufferActive: false,
            readCell: { column, _ in column == 0 ? "a" : nil },
            now: start.addingTimeInterval(0.2)
        )
        XCTAssertTrue(engine.echoConfirmedThisBurst)
        // Backspacing a confirmed character: the server cursor is about to
        // move where we can't see, so the burst must end.
        engine.noteKey(
            .backspace, cursor: (x: 1, y: 5), columns: 80,
            alternateBufferActive: false, now: start.addingTimeInterval(0.3)
        )
        XCTAssertFalse(engine.echoConfirmedThisBurst)
        let next = start.addingTimeInterval(0.35)
        type("b", cursorX: 1, at: next)
        XCTAssertEqual(engine.displayGlyphs(now: next), [])
    }

    func testWrapEndsTheBurst() {
        type("a", cursorX: 78, columns: 80)
        engine.reconcile(
            cursor: (x: 79, y: 5),
            alternateBufferActive: false,
            readCell: { column, _ in column == 78 ? "a" : nil },
            now: start.addingTimeInterval(0.2)
        )
        XCTAssertTrue(engine.echoConfirmedThisBurst)
        let next = start.addingTimeInterval(0.3)
        type("bc", cursorX: 79, at: next)
        XCTAssertTrue(engine.pending.isEmpty)
        XCTAssertFalse(engine.echoConfirmedThisBurst)
        XCTAssertEqual(engine.displayGlyphs(now: next), [])
    }

    func testControlKeyClears() {
        type("ls", cursorX: 0)
        engine.noteKey(
            .other, cursor: (x: 2, y: 5), columns: 80,
            alternateBufferActive: false, now: start
        )
        XCTAssertTrue(engine.pending.isEmpty)
    }

    func testWrapStopsPredicting() {
        // The last column itself is predictable; the character after it wraps
        // the line, which the shell may handle any number of ways — stop.
        type("a", cursorX: 79, columns: 80)
        XCTAssertEqual(engine.pending.map(\.column), [79])
        type("b", cursorX: 80, columns: 80)
        XCTAssertTrue(engine.pending.isEmpty)
    }

    func testPredictionsExpire() {
        type("a", cursorX: 0)
        engine.reconcile(
            cursor: (x: 0, y: 5),
            alternateBufferActive: false,
            readCell: { _, _ in nil },
            now: start.addingTimeInterval(6)
        )
        XCTAssertTrue(engine.pending.isEmpty)
    }
}
