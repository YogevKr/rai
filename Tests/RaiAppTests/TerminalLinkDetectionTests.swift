import AppKit
import SwiftTerm
import XCTest

@testable import RaiApp

/// Pins what SwiftTerm's Ghostty-style detector hands the link handler for a
/// path printed by Claude, so the resolver's trimming stays in step with it.
@MainActor
final class TerminalLinkDetectionTests: XCTestCase {
    private func detectedLink(in line: String, col: Int) -> String? {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 1200, height: 300))
        view.feed(text: line + "\r\n")
        return view.getTerminal().link(at: .screen(Position(col: col, row: 0)), mode: .explicitAndImplicit)
    }

    /// The sentence-ending period rides along: the path branch of the
    /// detector has no trailing-punctuation guard, so the resolver must drop it.
    func testTildePathIsHandedOverAsBareTextWithTheSentencePeriod() {
        let link = detectedLink(in: "It is also saved at ~/Downloads/scotty-playbook.html.", col: 25)
        XCTAssertEqual(link, "~/Downloads/scotty-playbook.html.")
        XCTAssertNil(URL(string: link ?? "")?.scheme, "a bare path must never reach NSWorkspace as a URL")
        XCTAssertEqual(
            LinkOpenResolver.resolve(
                link ?? "", cwd: nil, home: "/Users/tester", environment: [:],
                fileExists: { $0 == "/Users/tester/Downloads/scotty-playbook.html" }
            ),
            .file(URL(fileURLWithPath: "/Users/tester/Downloads/scotty-playbook.html"))
        )
    }

    func testDetectorKeepsTrailingSemicolonThatTheResolverDrops() {
        let link = detectedLink(in: "~/Downloads/scotty-playbook.html; { printf ok; }", col: 5)
        XCTAssertEqual(link, "~/Downloads/scotty-playbook.html;")
        XCTAssertEqual(
            LinkOpenResolver.resolve(
                link ?? "", cwd: nil, home: "/Users/tester", environment: [:],
                fileExists: { $0 == "/Users/tester/Downloads/scotty-playbook.html" }
            ),
            .file(URL(fileURLWithPath: "/Users/tester/Downloads/scotty-playbook.html"))
        )
    }

    func testCitationWithLineNumberResolvesAgainstThePane() {
        let link = detectedLink(in: "see Sources/RaiApp/RaiModel.swift:907 for the cwd fallback", col: 10)
        XCTAssertEqual(link, "Sources/RaiApp/RaiModel.swift:907")
        XCTAssertEqual(
            LinkOpenResolver.resolve(
                link ?? "", cwd: "/repo", home: "/Users/tester", environment: [:],
                fileExists: { $0 == "/repo/Sources/RaiApp/RaiModel.swift" }
            ),
            .file(URL(fileURLWithPath: "/repo/Sources/RaiApp/RaiModel.swift"))
        )
    }
}
