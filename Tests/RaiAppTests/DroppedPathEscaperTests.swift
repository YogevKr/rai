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

    /// SwiftTerm 2's `pasteText` rewrites control bytes; a dropped path must
    /// reach the pty exactly as escaped, inside paste markers when asked.
    func testVerbatimPasteKeepsEscapedControlBytesAndBracketsOnRequest() {
        let line = DroppedPathEscaper.line(for: [URL(fileURLWithPath: "/tmp/a\u{1B}b c")])
        XCTAssertEqual(line, "/tmp/a\\\u{1B}b\\ c ")
        XCTAssertEqual(VerbatimPaste.bytes(line, bracketedPaste: false), Array(line.utf8))
        XCTAssertEqual(
            VerbatimPaste.bytes(line, bracketedPaste: true),
            Array("\u{1B}[200~".utf8) + Array(line.utf8) + Array("\u{1B}[201~".utf8)
        )
        XCTAssertTrue(VerbatimPaste.bytes(line, bracketedPaste: true).contains(0x1B))
    }
}
