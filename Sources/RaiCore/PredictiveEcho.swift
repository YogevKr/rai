import Foundation

/// Mosh-style predictive local echo for remote herds.
///
/// Over a high-latency link every keystroke's echo pays a full round trip
/// (211 ms via a relayed transatlantic tunnel, measured), so typing feels
/// dead. This engine tracks the characters the user just typed and lets the
/// UI paint them immediately at the cell where the server's echo is expected,
/// removing each one the moment the authoritative frame confirms it.
///
/// The engine is deliberately conservative — authority always wins:
/// - Only plain printable ASCII at the primary screen buffer is predicted.
///   Alternate-screen programs (TUIs) repaint their own UI and are
///   unpredictable, so any key while the alternate buffer is active clears.
/// - Any non-printable key (Enter, arrows, control chords, escape) clears all
///   pending predictions; the next frame repaints the truth.
/// - A cell that comes back from the server with *different* visible content
///   than predicted clears everything (a misprediction flash, exactly like
///   mosh).
/// - Predictions expire unconditionally after `ttl`.
///
/// Display is gated adaptively, also like mosh, and *conservatively for
/// secrets*: glyphs are shown only when the link has demonstrated slowness
/// (smoothed confirm latency above `displayLatencyThreshold`) AND the current
/// input burst has at least one server-confirmed echo. Every Enter/control
/// key starts a new burst with no confidence, so typing at a hidden-input
/// prompt (`sudo`, `ssh`, `read -s`) — always preceded by Enter — never
/// paints a single secret character. If echo stops mid-burst (a program
/// flips echo off without a boundary key), the unconfirmed queue is retracted
/// after `max(2 × smoothed latency, retractionFloor)` and confidence drops.
public final class PredictiveEchoEngine {
    public struct Prediction: Equatable {
        public let character: Character
        /// Zero-based buffer column where the echo is expected to land.
        public let column: Int
        /// Visible row the prediction was made on.
        public let row: Int
        public let madeAt: Date
    }

    public enum KeyClass {
        case printable(Character)
        case backspace
        case other
    }

    public private(set) var pending: [Prediction] = []

    /// Smoothed observed echo latency, seconds. Starts at zero so a fast herd
    /// never shows an overlay. Only confirmed echoes ever move it.
    public private(set) var smoothedConfirmLatency: TimeInterval = 0

    /// True once the current input burst has a server-confirmed echo — the
    /// evidence that the program at the other end is echoing what we type.
    public private(set) var echoConfirmedThisBurst = false

    private let ttl: TimeInterval
    private let displayLatencyThreshold: TimeInterval
    private let retractionFloor: TimeInterval
    private let maxPending: Int

    public init(
        ttl: TimeInterval = 5.0,
        displayLatencyThreshold: TimeInterval = 0.06,
        retractionFloor: TimeInterval = 0.5,
        maxPending: Int = 32
    ) {
        self.ttl = ttl
        self.displayLatencyThreshold = displayLatencyThreshold
        self.retractionFloor = retractionFloor
        self.maxPending = maxPending
    }

    /// Records a keystroke aimed at the pty. `cursor` is the terminal's
    /// current visible cursor position, `columns` the pane width.
    public func noteKey(
        _ key: KeyClass,
        cursor: (x: Int, y: Int),
        columns: Int,
        alternateBufferActive: Bool,
        now: Date = Date()
    ) {
        if alternateBufferActive {
            pending.removeAll()
            echoConfirmedThisBurst = false
            return
        }
        switch key {
        case .printable(let character):
            let column = pending.last.map { $0.column + 1 } ?? cursor.x
            let row = pending.first?.row ?? cursor.y
            // A prediction that would wrap the line is unpredictable (the
            // shell may soft-wrap, scroll, or neither) — stop predicting AND
            // end the burst: the server cursor is about to move somewhere we
            // can't model, so later keys must stay hidden until re-proven.
            guard column < columns, pending.count < maxPending else {
                pending.removeAll()
                echoConfirmedThisBurst = false
                return
            }
            pending.append(
                Prediction(character: character, column: column, row: row, madeAt: now)
            )
        case .backspace:
            // Un-typing a not-yet-confirmed character just retracts the
            // prediction. With nothing pending the server owns the effect —
            // its cursor is about to move where we can't see yet, so end the
            // burst rather than predict the next key one column too far right.
            if pending.isEmpty {
                echoConfirmedThisBurst = false
            } else {
                pending.removeLast()
            }
        case .other:
            // A boundary key (Enter, control chord, escape) ends the burst.
            // Whatever prompt follows must re-prove that it echoes before
            // anything is displayed again — this is the password guard.
            pending.removeAll()
            echoConfirmedThisBurst = false
        }
    }

    /// Prunes the queue against the authoritative screen. `readCell` returns
    /// the visible character at (column, row) or nil for blank/unknown.
    public func reconcile(
        cursor: (x: Int, y: Int),
        alternateBufferActive: Bool,
        readCell: (_ column: Int, _ row: Int) -> Character?,
        now: Date = Date()
    ) {
        guard !pending.isEmpty else { return }
        if alternateBufferActive {
            pending.removeAll()
            echoConfirmedThisBurst = false
            return
        }
        // No echo inside the retraction window means the program has stopped
        // echoing (echo turned off mid-burst): retract everything on screen
        // and drop confidence so nothing further displays.
        let retractionDeadline = max(smoothedConfirmLatency * 2, retractionFloor)
        if let oldest = pending.first,
           now.timeIntervalSince(oldest.madeAt) > retractionDeadline {
            pending.removeAll()
            echoConfirmedThisBurst = false
            return
        }
        pending.removeAll { now.timeIntervalSince($0.madeAt) > ttl }
        guard let expectedRow = pending.first?.row else { return }
        // The prompt line moved (output scrolled in, prompt redrawn):
        // predictions no longer point at real cells.
        guard cursor.y == expectedRow else {
            pending.removeAll()
            return
        }
        while let first = pending.first {
            let cell = readCell(first.column, first.row)
            if cell == first.character, cursor.x > first.column {
                recordConfirmLatency(now.timeIntervalSince(first.madeAt))
                pending.removeFirst()
            } else if let cell, cell != first.character, cell != " " {
                // The server put something else there — misprediction.
                pending.removeAll()
                echoConfirmedThisBurst = false
                return
            } else {
                return
            }
        }
    }

    /// The glyphs the overlay should draw right now, offset in cells from the
    /// terminal's caret. Empty until the link has demonstrated slowness AND
    /// this burst has a confirmed echo — never gated on elapsed time alone,
    /// which would paint hidden input (passwords) that no echo will confirm.
    public func displayGlyphs(now: Date = Date()) -> [Character] {
        guard !pending.isEmpty,
              echoConfirmedThisBurst,
              smoothedConfirmLatency > displayLatencyThreshold
        else { return [] }
        return pending.map(\.character)
    }

    public func clear() {
        pending.removeAll()
        echoConfirmedThisBurst = false
    }

    private func recordConfirmLatency(_ latency: TimeInterval) {
        echoConfirmedThisBurst = true
        smoothedConfirmLatency = smoothedConfirmLatency == 0
            ? latency
            : smoothedConfirmLatency * 0.7 + latency * 0.3
    }
}
