import RaiCore
import XCTest

final class PaneInputTokenizerTests: XCTestCase {
    func testComposedLineSplitsIntoTextThenEnter() {
        XCTAssertEqual(
            PaneInputTokenizer.tokenize(Array("echo hi".utf8) + [0x0D]),
            [.text("echo hi"), .keys(["enter"])]
        )
    }

    func testLoneEnter() {
        XCTAssertEqual(PaneInputTokenizer.tokenize([0x0D]), [.keys(["enter"])])
        XCTAssertEqual(PaneInputTokenizer.tokenize([0x0A]), [.keys(["enter"])])
    }

    func testBackspaceVariantsBecomeKeys() {
        XCTAssertEqual(PaneInputTokenizer.tokenize([0x7F]), [.keys(["backspace"])])
        XCTAssertEqual(PaneInputTokenizer.tokenize([0x08]), [.keys(["backspace"])])
    }

    func testArrowsAndEscape() {
        XCTAssertEqual(
            PaneInputTokenizer.tokenize([0x1B, 0x5B, 0x41]),
            [.keys(["up"])]
        )
        XCTAssertEqual(
            PaneInputTokenizer.tokenize([0x1B, 0x5B, 0x44]),
            [.keys(["left"])]
        )
        XCTAssertEqual(PaneInputTokenizer.tokenize([0x1B]), [.keys(["escape"])])
    }

    func testControlBytesBecomeCtrlKeys() {
        XCTAssertEqual(PaneInputTokenizer.tokenize([0x03]), [.keys(["ctrl+c"])])
        XCTAssertEqual(PaneInputTokenizer.tokenize([0x12]), [.keys(["ctrl+r"])])
        XCTAssertEqual(PaneInputTokenizer.tokenize([0x1A]), [.keys(["ctrl+z"])])
    }

    func testConsecutiveKeysMerge() {
        XCTAssertEqual(
            PaneInputTokenizer.tokenize([0x7F, 0x7F, 0x0D]),
            [.keys(["backspace", "backspace", "enter"])]
        )
    }

    func testMixedTextAndKeysPreserveOrder() {
        XCTAssertEqual(
            PaneInputTokenizer.tokenize(Array("ab".utf8) + [0x7F] + Array("c".utf8)),
            [.text("ab"), .keys(["backspace"]), .text("c")]
        )
    }

    func testUnknownEscapeSequencePassesThroughAsText() {
        // Shift-Tab (CSI Z) has no herdr key name; raw-mode TUIs read it fine.
        XCTAssertEqual(
            PaneInputTokenizer.tokenize([0x1B, 0x5B, 0x5A]),
            [.text("\u{1B}[Z")]
        )
    }

    func testUTF8TextSurvives() {
        XCTAssertEqual(
            PaneInputTokenizer.tokenize(Array("שלום 👋".utf8)),
            [.text("שלום 👋")]
        )
    }
}
