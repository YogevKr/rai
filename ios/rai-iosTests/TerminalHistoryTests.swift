import RaiCore
import SwiftTerm
import UIKit
import XCTest
@testable import rai

@MainActor
final class TerminalHistoryTests: XCTestCase {
    private func view(rows: Int = 4, cols: Int = 80) -> GridReadableTerminalView {
        let view = GridReadableTerminalView(frame: CGRect(x: 0, y: 0, width: 650, height: 60))
        view.setScrollback(2_000)
        view.pinGridSize(cols: cols, rows: rows)
        return view
    }

    private func history(_ lines: [String]) -> Data {
        Data((lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n") + "\u{1B}[0m").utf8)
    }

    private func rows(_ view: GridReadableTerminalView) -> [String] {
        Array(String(decoding: view.getBufferAsData(), as: UTF8.self)
            .components(separatedBy: "\n").dropLast())
    }

    private func paint(_ lines: [String], on view: GridReadableTerminalView) {
        let frame = "\u{1B}[H\u{1B}[2J" + lines.enumerated().map {
            "\u{1B}[\($0.offset + 1);1H\($0.element)"
        }.joined()
        view.receiveFrame(Data(frame.utf8), full: true, grid: nil)
    }

    func testFirstFramePreservesEveryHistoryRowAtNativeGridSize() {
        let view = view(rows: 12, cols: 40)
        view.receiveHistory(history(["a", "a", "a", "a"]))
        view.pinGridSize(cols: 80, rows: 4)
        paint(["b", "b", "b", "b"], on: view)
        XCTAssertEqual(rows(view), ["a", "a", "a", "a", "b", "b", "b", "b"])
    }

    func testRefreshRestoresRepeatedIntermediateRowsWithoutReplacingTheLiveGrid() {
        let view = view()
        view.receiveHistory(history(Array(repeating: "a", count: 4)))
        paint(Array(repeating: "b", count: 4), on: view)
        paint(Array(repeating: "c", count: 4), on: view)
        view.receiveHistory(history(Array(repeating: "a", count: 4) + Array(repeating: "b", count: 4)))
        XCTAssertEqual(rows(view), Array(repeating: "a", count: 4) + Array(repeating: "b", count: 4) + Array(repeating: "c", count: 4))
    }

    func testRefreshPreservesCursorCellStylesUnicodeAndSubsequentDelta() {
        let view = view()
        view.receiveHistory(history(["old"]))
        paint(["\u{1B}[31mשלום 🙂", "\u{1B}[32mgreen"], on: view)
        let cursor = view.cursorPosition
        let attribute = view.visibleCell(col: 0, row: 1)?.attribute
        let grid = view.liveGridText()
        view.receiveHistory(history(["old", "new"]))
        XCTAssertEqual(view.liveGridText(), grid)
        XCTAssertEqual(view.cursorPosition, cursor)
        XCTAssertEqual(view.visibleCell(col: 0, row: 1)?.attribute, attribute)
        view.receiveFrame(Data("!".utf8), kind: .delta, grid: nil)
        XCTAssertTrue(view.liveGridText().contains("green!"))
        XCTAssertEqual(view.visibleCell(col: 5, row: 1)?.attribute, attribute)
    }

    func testHistoryRefreshKeepsStyledBlankRowTails() {
        let view = view()
        view.receiveHistory(history(["old"]))
        // A red erase-to-end-of-line leaves null cells that carry a background.
        paint(["\u{1B}[41mred\u{1B}[K\u{1B}[0m", "plain"], on: view)
        let tail = view.visibleCell(col: 10, row: 0)?.attribute
        XCTAssertEqual(tail?.bg, .ansi256(code: 1))
        view.receiveHistory(history(["old", "new"]))
        XCTAssertEqual(view.visibleRowText(0), "red")
        XCTAssertEqual(view.visibleCell(col: 3, row: 0)?.attribute, tail)
        XCTAssertEqual(view.visibleCell(col: 79, row: 0)?.attribute, tail)
        XCTAssertEqual(view.visibleCell(col: 10, row: 1)?.attribute.bg, CharData.Null.attribute.bg)
    }

    func testHistoryRefreshSeedsAsciiWhileLineDrawingIsActive() {
        let view = view()
        view.receiveHistory(history(["old"]))
        // The stream designates DEC line drawing in G0 and leaves it active.
        paint(["\u{1B}(0lqk"], on: view)
        XCTAssertEqual(view.visibleRowText(0), "┌─┐")
        view.receiveHistory(history(["old", "abc"]))
        XCTAssertEqual(rows(view).prefix(3), ["old", "abc", "┌─┐"])
        // DECRC restores the active set: the next delta still draws lines.
        view.receiveFrame(Data("x".utf8), kind: .delta, grid: nil)
        XCTAssertEqual(view.visibleRowText(0), "┌─┐│")
    }

    func testUnchangedHistoryDoesNotRebuildTheBuffer() {
        let view = view()
        let data = history(["old"])
        view.receiveHistory(data)
        paint(["live"], on: view)
        let firstLine = view.mirroredTerminal.getScrollInvariantLine(row: 0)
        view.receiveHistory(data)
        XCTAssertTrue(firstLine === view.mirroredTerminal.getScrollInvariantLine(row: 0))
    }

    func testLargerGridRestoresHistoryConsumedByTheResize() {
        let view = view()
        let historyRows = (0..<20).map { "history \($0)" }
        let data = history(historyRows)
        view.receiveHistory(data)
        paint(["old live"], on: view)
        view.receiveHistory(data)
        view.pinGridSize(cols: 80, rows: 8)
        let screen = (0..<8).map { "live \($0)" }
        paint(screen, on: view)
        view.receiveHistory(data)
        XCTAssertEqual(rows(view), historyRows + screen)
    }

    func testHistoryRefreshMovesTheNativeCaretWithoutAnotherFrame() async throws {
        let view = view()
        // SwiftTerm 2 places the caret on its display-link frame, and that
        // link only ticks for a view inside a window.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 700, height: 400))
        window.addSubview(view)
        window.isHidden = false
        defer { window.isHidden = true }
        view.receiveHistory(history(["old"]))
        paint(["live"], on: view)
        try await Task.sleep(for: .milliseconds(100))
        let oldCaret = view.caretFrame
        view.receiveHistory(history(["old", "new", "newer"]))
        try await Task.sleep(for: .milliseconds(100))
        let cellHeight = view.getOptimalFrameSize().height / CGFloat(view.terminalDimensions.rows)
        XCTAssertEqual(view.caretFrame.origin.y, oldCaret.origin.y + 2 * cellHeight, accuracy: 0.5)
        XCTAssertEqual(view.caretFrame.origin.x, oldCaret.origin.x, accuracy: 0.5)
    }

    func testEmptyHistoryClearsTheOldHistoryAndKeepsTheScreen() {
        let view = view()
        view.receiveHistory(history(["old"]))
        paint(["live"], on: view)
        view.receiveHistory(Data())
        XCTAssertEqual(rows(view), ["live", "", "", ""])
    }

    func testHistoryRefreshKeepsTheScrolledViewport() {
        let view = view()
        view.receiveHistory(history((0..<20).map { "row \($0)" }))
        paint(["live"], on: view)
        view.scrollTo(row: 5)
        let offset = view.contentOffset
        view.receiveHistory(history((0..<24).map { "row \($0)" }))
        XCTAssertEqual(view.viewportTop, 5)
        XCTAssertEqual(view.contentOffset.y, offset.y, accuracy: 0.5)
        XCTAssertEqual(view.visibleRowText(0), "row 5")
    }

    func testHistoryTrimmingKeepsTheSameScrolledText() {
        let view = view()
        view.receiveHistory(history((0..<20).map { "row \($0)" }))
        paint(["live"], on: view)
        view.scrollTo(row: 5)
        view.receiveHistory(history((3..<23).map { "row \($0)" }))
        XCTAssertEqual(view.viewportTop, 2)
        XCTAssertEqual(view.visibleRowText(0), "row 5")
    }

    func testHistoryTrimmingDistinguishesRepeatedRowsByTheirColors() {
        let view = view()
        func coloredRows(_ range: Range<Int>) -> Data {
            history(range.map { "\u{1B}[38;5;\($0)msame" })
        }
        view.receiveHistory(coloredRows(0..<20))
        paint(["live"], on: view)
        view.scrollTo(row: 5)
        let attribute = view.visibleCell(col: 0, row: 0)?.attribute
        view.receiveHistory(coloredRows(3..<23))
        XCTAssertEqual(view.viewportTop, 2)
        XCTAssertEqual(view.visibleCell(col: 0, row: 0)?.attribute, attribute)
    }

    func testSelectionDefersHistoryReplacementUntilSelectionEnds() async throws {
        let view = view()
        view.receiveHistory(history(["old"]))
        paint(["live"], on: view)
        view.setSelectionRange(start: Position(col: 0, row: 0), end: Position(col: 3, row: 0))
        view.receiveHistory(history(["old", "new"]))
        XCTAssertEqual(rows(view).first, "old")
        XCTAssertEqual(rows(view).count, 5)
        XCTAssertNotNil(view.getSelectionRange())
        view.clearSelection()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(rows(view).prefix(2), ["old", "new"])
    }
}

extension PhoneLinkTerminalView {
    /// The first buffer row on screen, from the view's copied state.
    var viewportTop: Int { terminalStateSnapshot().viewportRow }

    /// Text of one screen row, right-trimmed, from the view's copied state.
    func visibleRowText(_ row: Int) -> String? {
        guard let line = terminalStateSnapshot().visibleRows.first(where: { $0.row == row }) else { return nil }
        var text = line.text
        while text.last == " " { text.removeLast() }
        return text
    }

    /// One styled cell of a screen row. Styles live only in the mirror.
    func visibleCell(col: Int, row: Int) -> CharData? {
        let mirror = mirroredTerminal
        return mirror.getScrollInvariantLine(row: mirror.buffer.totalLinesTrimmed + viewportTop + row)?[col]
    }
}
