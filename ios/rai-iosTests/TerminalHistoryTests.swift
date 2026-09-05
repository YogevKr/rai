import RaiCore
import SwiftTerm
import UIKit
import XCTest
@testable import rai

@MainActor
final class TerminalHistoryTests: XCTestCase {
    private func view(rows: Int = 4, cols: Int = 80) -> GridReadableTerminalView {
        let view = GridReadableTerminalView(frame: CGRect(x: 0, y: 0, width: 650, height: 60))
        view.changeScrollback(2_000)
        view.pinGridSize(cols: cols, rows: rows)
        return view
    }

    private func history(_ lines: [String]) -> Data {
        Data((lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n") + "\u{1B}[0m").utf8)
    }

    private func rows(_ view: GridReadableTerminalView) -> [String] {
        Array(String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self)
            .components(separatedBy: "\n").dropLast())
    }

    private func paint(_ lines: [String], on view: GridReadableTerminalView) {
        view.prepareHistoryForFrame()
        view.feed(text: "\u{1B}[H\u{1B}[2J" + lines.enumerated().map {
            "\u{1B}[\($0.offset + 1);1H\($0.element)"
        }.joined())
        view.hasLiveFrame = true
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
        let terminal = view.getTerminal()
        let cursor = terminal.getCursorLocation()
        let attribute = terminal.getCharData(col: 0, row: 1)?.attribute
        let grid = view.liveGridText()
        view.receiveHistory(history(["old", "new"]))
        XCTAssertEqual(view.liveGridText(), grid)
        XCTAssertEqual(terminal.getCursorLocation().x, cursor.x)
        XCTAssertEqual(terminal.getCursorLocation().y, cursor.y)
        XCTAssertEqual(terminal.getCharData(col: 0, row: 1)?.attribute, attribute)
        view.feed(text: "!")
        XCTAssertTrue(view.liveGridText().contains("green!"))
        XCTAssertEqual(terminal.getCharData(col: 5, row: 1)?.attribute, attribute)
    }

    func testUnchangedHistoryDoesNotRebuildTheBuffer() {
        let view = view()
        let data = history(["old"])
        view.receiveHistory(data)
        paint(["live"], on: view)
        let firstLine = view.getTerminal().getScrollInvariantLine(row: 0)
        view.receiveHistory(data)
        XCTAssertTrue(firstLine === view.getTerminal().getScrollInvariantLine(row: 0))
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
        view.receiveHistory(history(["old"]))
        paint(["live"], on: view)
        try await Task.sleep(for: .milliseconds(50))
        let oldCaret = view.caretFrame
        view.receiveHistory(history(["old", "new", "newer"]))
        try await Task.sleep(for: .milliseconds(50))
        let cellHeight = view.getOptimalFrameSize().height / CGFloat(view.getTerminal().rows)
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
        XCTAssertEqual(view.getTerminal().buffer.yDisp, 5)
        XCTAssertEqual(view.contentOffset.y, offset.y, accuracy: 0.5)
        XCTAssertEqual(view.getTerminal().getLine(row: 0)?.translateToString(trimRight: true), "row 5")
    }

    func testHistoryTrimmingKeepsTheSameScrolledText() {
        let view = view()
        view.receiveHistory(history((0..<20).map { "row \($0)" }))
        paint(["live"], on: view)
        view.scrollTo(row: 5)
        view.receiveHistory(history((3..<23).map { "row \($0)" }))
        XCTAssertEqual(view.getTerminal().buffer.yDisp, 2)
        XCTAssertEqual(view.getTerminal().getLine(row: 0)?.translateToString(trimRight: true), "row 5")
    }

    func testHistoryTrimmingDistinguishesRepeatedRowsByTheirColors() {
        let view = view()
        func coloredRows(_ range: Range<Int>) -> Data {
            history(range.map { "\u{1B}[38;5;\($0)msame" })
        }
        view.receiveHistory(coloredRows(0..<20))
        paint(["live"], on: view)
        view.scrollTo(row: 5)
        let attribute = view.getTerminal().getLine(row: 0)?[0].attribute
        view.receiveHistory(coloredRows(3..<23))
        XCTAssertEqual(view.getTerminal().buffer.yDisp, 2)
        XCTAssertEqual(view.getTerminal().getLine(row: 0)?[0].attribute, attribute)
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
