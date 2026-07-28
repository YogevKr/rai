/// Pure bookkeeping for a selection that extends into herdr-side scrollback.
///
/// rai's pane terminal is an alt-screen viewport onto a pane whose scrollback
/// lives in herdr. To select past the visible screen, the app scrolls the pane
/// host-side (via the attach stream) and pages the revealed content with
/// `pane.read`. This model does the coordinate math and text assembly:
///
/// - Lines are addressed by an **absolute index**: the line's distance from the
///   top of the pane's whole buffer, `(maxOffsetFromBottom - offsetFromBottom)
///   + visibleRow`. It is stable while the pane scrolls (and while output
///   appends, until scrollback trimming).
/// - Every page read during the gesture is ingested into a line store, so the
///   final copy is assembled from content the user actually scrolled through —
///   no reconstruction guesswork.
public struct ScrollbackSelectionModel: Sendable {
    public struct Point: Equatable, Sendable {
        public var row: Int   // absolute line index
        public var col: Int
        public init(row: Int, col: Int) {
            self.row = row
            self.col = col
        }
    }

    public private(set) var lines: [Int: String] = [:]
    public private(set) var anchor: Point?
    public private(set) var head: Point?

    public init() {}

    /// The absolute index of the top visible row for the given scroll state.
    public static func absoluteTop(of scroll: PaneScroll) -> Int {
        scroll.maxOffsetFromBottom - scroll.offsetFromBottom
    }

    public var isActive: Bool { anchor != nil }

    /// Whether the selection spans beyond a single visible screen's rows.
    public func extendsBeyondViewport(rows: Int) -> Bool {
        guard let anchor, let head else { return false }
        return abs(anchor.row - head.row) >= rows
    }

    public mutating func begin(anchorVisibleRow: Int, col: Int, scroll: PaneScroll) {
        let point = Point(row: Self.absoluteTop(of: scroll) + anchorVisibleRow, col: col)
        anchor = point
        head = point
    }

    public mutating func extendHead(visibleRow: Int, col: Int, scroll: PaneScroll) {
        head = Point(row: Self.absoluteTop(of: scroll) + visibleRow, col: col)
    }

    /// Stores one visible-page read (`pane.read`, ANSI-stripped) at the page's
    /// absolute position. Later reads of the same rows overwrite older ones.
    public mutating func ingest(pageText: String, scroll: PaneScroll) {
        let top = Self.absoluteTop(of: scroll)
        var row = top
        // Swift groups "\r\n" into ONE grapheme, so a split on "\n" alone
        // would never separate CRLF-terminated rows — normalize first.
        let normalized = pageText.replacingOccurrences(of: "\r\n", with: "\n")
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if line.hasSuffix("\r") { line.removeLast() }
            lines[row] = line
            row += 1
        }
    }

    public mutating func reset() {
        lines = [:]
        anchor = nil
        head = nil
    }

    /// The selection's ordered absolute range (start is the earlier position).
    public func orderedRange() -> (start: Point, end: Point)? {
        guard let anchor, let head else { return nil }
        if anchor.row < head.row || (anchor.row == head.row && anchor.col <= head.col) {
            return (anchor, head)
        }
        return (head, anchor)
    }

    /// The part of the selection currently on screen, in visible-row
    /// coordinates, for painting the terminal's highlight. Rows clamped to the
    /// viewport; a clamped start begins at column 0 and a clamped end runs to
    /// `clampedEndColumn` (large, for the terminal layer to clamp to its width).
    public static let clampedEndColumn = 100_000

    public func visibleHighlight(
        scroll: PaneScroll
    ) -> (startRow: Int, startCol: Int, endRow: Int, endCol: Int)? {
        guard let range = orderedRange() else { return nil }
        let top = Self.absoluteTop(of: scroll)
        let bottom = top + scroll.viewportRows - 1
        guard range.end.row >= top, range.start.row <= bottom else { return nil }
        let startClamped = range.start.row < top
        let endClamped = range.end.row > bottom
        return (
            startRow: max(range.start.row, top) - top,
            startCol: startClamped ? 0 : range.start.col,
            endRow: min(range.end.row, bottom) - top,
            endCol: endClamped ? Self.clampedEndColumn : range.end.col
        )
    }

    /// Assembles the selected text from the ingested line store. The first
    /// line starts at the start column, the last ends at the end column
    /// (inclusive); rows never ingested are skipped.
    public func assembledText() -> String? {
        guard let range = orderedRange() else { return nil }
        var out: [String] = []
        for row in range.start.row...range.end.row {
            guard var line = lines[row] else { continue }
            if row == range.end.row, range.end.col + 1 < line.count {
                line = String(line.prefix(range.end.col + 1))
            }
            if row == range.start.row, range.start.col > 0 {
                line = String(line.dropFirst(min(range.start.col, line.count)))
            }
            out.append(line)
        }
        guard !out.isEmpty else { return nil }
        // Trailing spaces are rendering artifacts of fixed-width rows.
        return out.map { line in
            var l = line
            while l.hasSuffix(" ") { l.removeLast() }
            return l
        }.joined(separator: "\n")
    }
}
