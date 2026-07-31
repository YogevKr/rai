import RaiCore
import XCTest

final class CopyModeStateTests: XCTestCase {
    private let lines = [
        0: "foo.bar_baz",
        1: "second line",
        2: "",
        3: "final NEEDLE needle",
    ]

    private func state(row: Int = 0, col: Int = 0) -> CopyModeState {
        CopyModeState(
            cursor: .init(row: row, col: col),
            rowBounds: 0...3,
            columns: 20,
            viewportRows: 4
        )
    }

    func testVisualSelectionKeepsAbsoluteAnchorAcrossMotions() {
        var copyMode = state(row: 1, col: 3)
        XCTAssertEqual(copyMode.reduce(.character("v"), lines: lines), .none)
        XCTAssertEqual(copyMode.anchor, .init(row: 1, col: 3))

        copyMode.reduce(.character("k"), lines: lines)
        copyMode.reduce(.character("h"), lines: lines)

        XCTAssertEqual(copyMode.cursor, .init(row: 0, col: 2))
        XCTAssertEqual(copyMode.anchor, .init(row: 1, col: 3))
        XCTAssertEqual(copyMode.mode, .visual)
        XCTAssertEqual(copyMode.reduce(.character("y"), lines: lines), .yank)
    }

    func testEscapeClearsVisualOrSearchBeforeItExits() {
        var copyMode = state()
        copyMode.reduce(.character("v"), lines: lines)
        XCTAssertEqual(copyMode.reduce(.escape, lines: lines), .none)
        XCTAssertNil(copyMode.anchor)
        XCTAssertEqual(copyMode.reduce(.escape, lines: lines), .exit)

        copyMode = state()
        copyMode.applySearch(
            query: "foo",
            direction: .forward,
            matches: CopyModeState.matches(query: "foo", in: lines),
            isComplete: true,
            repeatSearch: false
        )
        XCTAssertEqual(copyMode.reduce(.escape, lines: lines), .none)
        XCTAssertNil(copyMode.searchResult)
        XCTAssertEqual(copyMode.reduce(.escape, lines: lines), .exit)
    }

    func testWordMotionsUseHerdrSeparatorClasses() {
        var copyMode = state()
        copyMode.reduce(.character("w"), lines: lines)
        XCTAssertEqual(copyMode.cursor, .init(row: 0, col: 3))
        copyMode.reduce(.character("w"), lines: lines)
        XCTAssertEqual(copyMode.cursor, .init(row: 0, col: 4))
        copyMode.reduce(.character("e"), lines: lines)
        XCTAssertEqual(copyMode.cursor, .init(row: 0, col: 10))
        copyMode.reduce(.character("w"), lines: lines)
        XCTAssertEqual(copyMode.cursor, .init(row: 1, col: 0))
        copyMode.reduce(.character("b"), lines: lines)
        XCTAssertEqual(copyMode.cursor, .init(row: 0, col: 4))
    }

    func testParagraphMotionsStopOnBlankRows() {
        var copyMode = state(row: 0)
        copyMode.reduce(.character("}"), lines: lines)
        XCTAssertEqual(copyMode.cursor.row, 2)
        copyMode.reduce(.character("{"), lines: lines)
        XCTAssertEqual(copyMode.cursor.row, 0)
    }

    func testSearchPromptAndSmartCaseMatchCounts() {
        var copyMode = state()
        copyMode.reduce(.character("/"), lines: lines)
        copyMode.reduce(.character("n"), lines: lines)
        copyMode.reduce(.character("e"), lines: lines)
        copyMode.reduce(.character("e"), lines: lines)
        copyMode.reduce(.character("d"), lines: lines)
        XCTAssertEqual(
            copyMode.reduce(.enter, lines: lines),
            .search(query: "need", direction: .forward, repeatSearch: false)
        )

        let insensitive = CopyModeState.matches(query: "needle", in: lines)
        XCTAssertEqual(insensitive.count, 2)
        let sensitive = CopyModeState.matches(query: "NEEDLE", in: lines)
        XCTAssertEqual(sensitive.count, 1)
    }

    func testSearchMovesAndWrapsInBothDirections() {
        let matches = CopyModeState.matches(query: "needle", in: lines)
        var copyMode = state(row: 3, col: 0)
        copyMode.applySearch(
            query: "needle",
            direction: .forward,
            matches: matches,
            isComplete: true,
            repeatSearch: false
        )
        XCTAssertEqual(copyMode.searchResult?.currentIndex, 0)
        XCTAssertEqual(copyMode.cursor.col, 6)

        copyMode.applySearch(
            query: "needle",
            direction: .forward,
            matches: matches,
            isComplete: true,
            repeatSearch: true
        )
        XCTAssertEqual(copyMode.searchResult?.currentIndex, 1)
        XCTAssertEqual(copyMode.cursor.col, 13)

        copyMode.applySearch(
            query: "needle",
            direction: .backward,
            matches: matches,
            isComplete: true,
            repeatSearch: true
        )
        XCTAssertEqual(copyMode.searchResult?.currentIndex, 0)
    }

    func testPageAndHistoryMotionsClampToBounds() {
        var copyMode = state(row: 3, col: 10)
        copyMode.reduce(.pageUp, lines: lines)
        XCTAssertEqual(copyMode.cursor.row, 1)
        copyMode.reduce(.character("g"), lines: lines)
        XCTAssertEqual(copyMode.cursor.row, 0)
        copyMode.reduce(.character("G"), lines: lines)
        XCTAssertEqual(copyMode.cursor.row, 3)
        copyMode.reduce(.character("$"), lines: lines)
        XCTAssertEqual(copyMode.cursor.col, 18)
        copyMode.reduce(.character("^"), lines: lines)
        XCTAssertEqual(copyMode.cursor.col, 0)
    }

    func testWideCharactersUseTerminalCellColumns() {
        let wideLines = [0: "a界 z", 1: "find 界 now"]
        var copyMode = CopyModeState(
            cursor: .init(row: 0, col: 0),
            rowBounds: 0...1,
            columns: 20,
            viewportRows: 2
        )
        copyMode.reduce(.character("$"), lines: wideLines)
        XCTAssertEqual(copyMode.cursor.col, 4)

        copyMode = CopyModeState(
            cursor: .init(row: 0, col: 2),
            rowBounds: 0...1,
            columns: 20,
            viewportRows: 2
        )
        copyMode.reduce(.character("w"), lines: wideLines)
        XCTAssertEqual(copyMode.cursor.col, 4)

        let matches = CopyModeState.matches(query: "界", in: wideLines)
        XCTAssertEqual(matches[0].start, .init(row: 0, col: 1))
        XCTAssertEqual(matches[0].end, .init(row: 0, col: 2))
        XCTAssertEqual(matches[1].start, .init(row: 1, col: 5))
    }
}
