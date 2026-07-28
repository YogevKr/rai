import RaiCore
import XCTest

final class ScrollbackSelectionModelTests: XCTestCase {
    private func scroll(offset: Int, max: Int, rows: Int = 25) -> PaneScroll {
        // Round-trips through the wire shape so the CodingKeys stay honest.
        let json = """
        {"offset_from_bottom": \(offset), "max_offset_from_bottom": \(max), "viewport_rows": \(rows)}
        """
        return try! JSONDecoder().decode(PaneScroll.self, from: Data(json.utf8))
    }

    func testAbsoluteTopTracksScrollOffset() {
        XCTAssertEqual(ScrollbackSelectionModel.absoluteTop(of: scroll(offset: 0, max: 300)), 300)
        XCTAssertEqual(ScrollbackSelectionModel.absoluteTop(of: scroll(offset: 48, max: 300)), 252)
    }

    func testUpwardSelectionAcrossPagesAssemblesInOrder() {
        var model = ScrollbackSelectionModel()
        let bottomPage = scroll(offset: 0, max: 100, rows: 4)
        // Visible rows are abs 100..103.
        model.ingest(pageText: "row-100\r\nrow-101\r\nrow-102\r\nrow-103", scroll: bottomPage)
        model.begin(anchorVisibleRow: 2, col: 6, scroll: bottomPage)   // abs 102, end of "row-102"

        let scrolled = scroll(offset: 3, max: 100, rows: 4)            // abs 97..100
        model.ingest(pageText: "row-097\r\nrow-098\r\nrow-099\r\nrow-100", scroll: scrolled)
        model.extendHead(visibleRow: 0, col: 0, scroll: scrolled)      // abs 97

        XCTAssertTrue(model.extendsBeyondViewport(rows: 4))
        XCTAssertEqual(
            model.assembledText(),
            "row-097\nrow-098\nrow-099\nrow-100\nrow-101\nrow-102"
        )
    }

    func testColumnsTrimFirstAndLastLine() {
        var model = ScrollbackSelectionModel()
        let page = scroll(offset: 0, max: 0, rows: 3)                  // abs 0..2
        model.ingest(pageText: "alpha beta\r\ngamma delta\r\nepsilon", scroll: page)
        model.begin(anchorVisibleRow: 0, col: 6, scroll: page)         // "beta"
        model.extendHead(visibleRow: 1, col: 4, scroll: page)          // "gamma"
        XCTAssertEqual(model.assembledText(), "beta\ngamma")
    }

    func testVisibleHighlightClampsToViewport() {
        var model = ScrollbackSelectionModel()
        let bottom = scroll(offset: 0, max: 100, rows: 10)
        model.begin(anchorVisibleRow: 5, col: 3, scroll: bottom)       // abs 105
        let scrolled = scroll(offset: 50, max: 100, rows: 10)          // abs 50..59
        model.extendHead(visibleRow: 0, col: 0, scroll: scrolled)      // abs 50

        let hl = model.visibleHighlight(scroll: scrolled)
        XCTAssertNotNil(hl)
        // Anchor (abs 105) is far below the screen: end clamps to the bottom
        // row with the run-to-end column; head is the top-left.
        XCTAssertEqual(hl?.startRow, 0)
        XCTAssertEqual(hl?.startCol, 0)
        XCTAssertEqual(hl?.endRow, 9)
        XCTAssertEqual(hl?.endCol, ScrollbackSelectionModel.clampedEndColumn)
    }

    func testHighlightNilWhenSelectionFullyOffScreen() {
        var model = ScrollbackSelectionModel()
        let bottom = scroll(offset: 0, max: 100, rows: 10)
        model.begin(anchorVisibleRow: 8, col: 0, scroll: bottom)       // abs 108
        model.extendHead(visibleRow: 9, col: 5, scroll: bottom)        // abs 109
        // Scrolled far up: abs 20..29 visible; selection (108..109) is below.
        XCTAssertNil(model.visibleHighlight(scroll: scroll(offset: 80, max: 100, rows: 10)))
    }

    func testLaterIngestOverwritesSameRows() {
        var model = ScrollbackSelectionModel()
        let page = scroll(offset: 0, max: 0, rows: 2)
        model.ingest(pageText: "old-a\r\nold-b", scroll: page)
        model.ingest(pageText: "new-a\r\nnew-b", scroll: page)
        model.begin(anchorVisibleRow: 0, col: 0, scroll: page)
        model.extendHead(visibleRow: 1, col: 9999, scroll: page)
        XCTAssertEqual(model.assembledText(), "new-a\nnew-b")
    }

    func testTrailingSpacesTrimmedFromAssembledLines() {
        var model = ScrollbackSelectionModel()
        let page = scroll(offset: 0, max: 0, rows: 2)
        model.ingest(pageText: "hello      \r\nworld  ", scroll: page)
        model.begin(anchorVisibleRow: 0, col: 0, scroll: page)
        model.extendHead(visibleRow: 1, col: 9999, scroll: page)
        XCTAssertEqual(model.assembledText(), "hello\nworld")
    }
}
