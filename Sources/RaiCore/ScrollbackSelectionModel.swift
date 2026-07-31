enum TerminalTextCells {
    struct Cell {
        let character: Character
        let start: Int
        let end: Int
    }

    static func cells(in text: String) -> [Cell] {
        var column = 0
        return text.map { character in
            let width = width(of: character)
            defer { column += width }
            return Cell(
                character: character,
                start: column,
                end: column + width - 1
            )
        }
    }

    static func width(of text: Substring) -> Int {
        text.reduce(0) { $0 + width(of: $1) }
    }

    static func width(of character: Character) -> Int {
        let scalars = character.unicodeScalars
        if scalars.contains(where: {
            $0.value == 0x200D
                || $0.properties.isEmojiPresentation
                || $0.value == 0xFE0F
                || (0x1F1E6...0x1F1FF).contains($0.value)
        }) {
            return 2
        }
        return max(1, scalars.map(scalarWidth).max() ?? 1)
    }

    private static func scalarWidth(_ scalar: UnicodeScalar) -> Int {
        let value = scalar.value
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .format:
            return 0
        default:
            break
        }
        if (0x1160...0x11FF).contains(value)
            || (0xD7B0...0xD7FF).contains(value) {
            return 0
        }
        return isEastAsianWide(value) ? 2 : 1
    }

    /// These stable Unicode blocks cover the wide cells emitted by terminals.
    private static func isEastAsianWide(_ value: UInt32) -> Bool {
        (0x1100...0x115F).contains(value)
            || value == 0x2329
            || value == 0x232A
            || ((0x2E80...0xA4CF).contains(value) && value != 0x303F)
            || (0xAC00...0xD7A3).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0xFE10...0xFE19).contains(value)
            || (0xFE30...0xFE6F).contains(value)
            || (0xFF00...0xFF60).contains(value)
            || (0xFFE0...0xFFE6).contains(value)
            || (0x16FE0...0x18DFF).contains(value)
            || (0x1AFF0...0x1B2FF).contains(value)
            || (0x1D300...0x1D37F).contains(value)
            || (0x20000...0x3FFFD).contains(value)
    }

    static func slice(
        _ text: String,
        from startColumn: Int?,
        through endColumn: Int?
    ) -> String {
        String(cells(in: text).compactMap { cell in
            if let startColumn, cell.end < startColumn { return nil }
            if let endColumn, cell.start > endColumn { return nil }
            return cell.character
        })
    }
}

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
        begin(anchor: point)
    }

    public mutating func begin(anchor point: Point) {
        anchor = point
        head = point
    }

    public mutating func extendHead(visibleRow: Int, col: Int, scroll: PaneScroll) {
        extendHead(to: Point(row: Self.absoluteTop(of: scroll) + visibleRow, col: col))
    }

    public mutating func extendHead(to point: Point) {
        head = point
    }

    /// Stores one visible-page read (`pane.read`, ANSI-stripped) at the page's
    /// absolute position. Later reads of the same rows overwrite older ones.
    @discardableResult
    public mutating func ingest(pageText: String, scroll: PaneScroll) -> Int {
        ingest(
            pageText: pageText,
            startingAt: Self.absoluteTop(of: scroll),
            maximumRows: scroll.viewportRows
        )
    }

    /// Stores text whose absolute first row is known, such as a recent-buffer read.
    @discardableResult
    public mutating func ingest(
        pageText: String,
        startingAt top: Int,
        maximumRows: Int? = nil
    ) -> Int {
        var row = top
        var count = 0
        // Swift groups "\r\n" into ONE grapheme, so a split on "\n" alone
        // would never separate CRLF-terminated rows — normalize first.
        let normalized = pageText.replacingOccurrences(of: "\r\n", with: "\n")
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if let maximumRows, count >= maximumRows { break }
            var line = String(rawLine)
            if line.hasSuffix("\r") { line.removeLast() }
            lines[row] = line
            row += 1
            count += 1
        }
        return count
    }

    public mutating func reset() {
        lines = [:]
        resetSelection()
    }

    public mutating func resetSelection() {
        anchor = nil
        head = nil
    }

    public func containsAllRows(in range: ClosedRange<Int>) -> Bool {
        range.allSatisfy { lines[$0] != nil }
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
            guard let source = lines[row] else { continue }
            let line = TerminalTextCells.slice(
                source,
                from: row == range.start.row ? range.start.col : nil,
                through: row == range.end.row ? range.end.col : nil
            )
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

    /// Assembles a complete pane buffer. Missing rows make the result invalid.
    public func assembledBufferText(rowCount: Int) -> String? {
        guard rowCount > 0, (0..<rowCount).allSatisfy({ lines[$0] != nil }) else {
            return nil
        }
        var copy = self
        copy.begin(anchor: Point(row: 0, col: 0))
        copy.extendHead(to: Point(row: rowCount - 1, col: Self.clampedEndColumn))
        return copy.assembledText()
    }
}
