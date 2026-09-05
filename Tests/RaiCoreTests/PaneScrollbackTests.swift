import Foundation
import XCTest
@testable import RaiCore

final class PaneScrollbackTests: XCTestCase {
    private func payload(_ recent: String, visible: String, rows: Int) -> String {
        String(decoding: PaneScrollback.payload(recent: recent, visible: visible, viewportRows: rows), as: UTF8.self)
    }

    func testBlankScreenTailDoesNotRemoveAnExtraHistoryRow() {
        XCTAssertEqual(payload("a\r\nb\r\nc", visible: "b\r\nc", rows: 3), "a\n\u{1B}[0m")
    }

    func testRepeatedRowsKeepTheirCount() {
        XCTAssertEqual(payload("a\na\na\na\nb\nb", visible: "b\nb", rows: 4), "a\na\na\na\n\u{1B}[0m")
    }

    func testEmptyVisibleScreenPreservesHistory() {
        XCTAssertEqual(payload("a\nb", visible: "", rows: 4), "a\nb\n\u{1B}[0m")
    }

    func testAltScreenWithoutHistoryHasAnEmptySeed() {
        XCTAssertEqual(payload("prompt\n", visible: "prompt\n", rows: 24), "")
    }

    func testStylesAndInteriorBlankRowsRemainInHistory() {
        XCTAssertEqual(payload("\u{1B}[31ma\n\nb\nc", visible: "c", rows: 4), "\u{1B}[31ma\n\nb\n\u{1B}[0m")
    }
}
