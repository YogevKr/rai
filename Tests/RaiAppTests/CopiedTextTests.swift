import XCTest

@testable import RaiApp

/// Copied terminal rows arrive padded to the pty's full width; pasting them
/// into anything that wraps folds every line into a bonus blank row.
final class CopiedTextTests: XCTestCase {
    func testStripsTrailingPaddingPerLine() {
        let padded = "line one" + String(repeating: " ", count: 200)
            + "\n" + String(repeating: " ", count: 264)
            + "\nlast\t "
        XCTAssertEqual(CopiedText.trimmed(padded), "line one\n\nlast")
    }

    func testPreservesInteriorWhitespaceAndBlankLines() {
        let text = "  indented ⎿ \u{00A0}kept\n\nnext"
        XCTAssertEqual(CopiedText.trimmed(text), "  indented ⎿ \u{00A0}kept\n\nnext")
    }
}
