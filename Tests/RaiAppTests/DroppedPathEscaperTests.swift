import Foundation
import XCTest

@testable import RaiApp

/// Dropping a file onto a pane types its shell-escaped path, Ghostty-style:
/// plain paths pass through untouched, everything the shell (or Claude's
/// @-path parsing) would interpret gets a backslash.
final class DroppedPathEscaperTests: XCTestCase {
    func testPlainPathIsUntouched() {
        XCTAssertEqual(
            DroppedPathEscaper.escape("/Users/yogev/projects/rai/Package.swift"),
            "/Users/yogev/projects/rai/Package.swift"
        )
    }

    func testSpacesAndShellSpecialsAreBackslashEscaped() {
        XCTAssertEqual(
            DroppedPathEscaper.escape("/tmp/My Report (final) & notes.pdf"),
            "/tmp/My\\ Report\\ \\(final\\)\\ \\&\\ notes.pdf"
        )
        XCTAssertEqual(
            DroppedPathEscaper.escape("/tmp/it's \"quoted\" $HOME `x`;|<>*?[]!#~"),
            "/tmp/it\\'s\\ \\\"quoted\\\"\\ \\$HOME\\ \\`x\\`\\;\\|\\<\\>\\*\\?\\[\\]\\!\\#\\~"
        )
    }

    func testBackslashInFilenameIsEscaped() {
        XCTAssertEqual(DroppedPathEscaper.escape("/tmp/a\\b"), "/tmp/a\\\\b")
    }

    func testMultipleURLsJoinWithTrailingSpace() {
        let urls = [
            URL(fileURLWithPath: "/tmp/one.txt"),
            URL(fileURLWithPath: "/tmp/two three.txt"),
        ]
        XCTAssertEqual(
            DroppedPathEscaper.line(for: urls),
            "/tmp/one.txt /tmp/two\\ three.txt "
        )
    }
}
