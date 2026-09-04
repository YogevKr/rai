import Foundation
import XCTest

@testable import RaiApp

/// ⌘-clicking a path in a pane must resolve it like the shell would and never
/// hand a scheme-less string to LaunchServices (Finder's "-50" alert).
final class LinkOpenResolverTests: XCTestCase {
    private let home = "/Users/tester"
    private let cwd = "/Users/tester/projects/rai"
    private let existing: Set<String> = [
        "/Users/tester/Downloads/scotty-playbook.html",
        "/Users/tester/projects/rai/Sources/RaiApp/RaiModel.swift",
        "/Users/tester/projects/Package.swift",
        "/Users/tester/projects/rai/docs",
        "/Users/tester/projects/rai/README",
    ]

    private func resolve(_ link: String, cwd: String? = nil, env: [String: String] = [:]) -> LinkOpenTarget {
        LinkOpenResolver.resolve(
            link,
            cwd: cwd ?? self.cwd,
            home: home,
            environment: env,
            fileExists: { self.existing.contains($0) }
        )
    }

    private func file(_ path: String) -> LinkOpenTarget {
        .file(URL(fileURLWithPath: path))
    }

    func testTildePathOpensTheFile() {
        XCTAssertEqual(
            resolve("~/Downloads/scotty-playbook.html"),
            file("/Users/tester/Downloads/scotty-playbook.html")
        )
    }

    func testTrailingPunctuationSwallowedByTheDetectorIsDropped() {
        XCTAssertEqual(
            resolve("~/Downloads/scotty-playbook.html;"),
            file("/Users/tester/Downloads/scotty-playbook.html")
        )
        XCTAssertEqual(
            resolve("~/Downloads/scotty-playbook.html)."),
            file("/Users/tester/Downloads/scotty-playbook.html")
        )
    }

    func testLineAndColumnCitationsOpenTheFile() {
        XCTAssertEqual(
            resolve("Sources/RaiApp/RaiModel.swift:907"),
            file("/Users/tester/projects/rai/Sources/RaiApp/RaiModel.swift")
        )
        XCTAssertEqual(
            resolve("./Sources/RaiApp/RaiModel.swift:907:17"),
            file("/Users/tester/projects/rai/Sources/RaiApp/RaiModel.swift")
        )
    }

    func testRelativePathsResolveAgainstThePaneDirectory() {
        XCTAssertEqual(resolve("../Package.swift"), file("/Users/tester/projects/Package.swift"))
        XCTAssertEqual(resolve("docs/"), file("/Users/tester/projects/rai/docs"))
        XCTAssertEqual(resolve("docs/", cwd: "~/projects/rai"), file("/Users/tester/projects/rai/docs"))
    }

    func testRelativePathWithoutADirectoryStaysUnresolved() {
        XCTAssertEqual(
            LinkOpenResolver.resolve(
                "docs/", cwd: nil, home: home, environment: [:],
                fileExists: { self.existing.contains($0) }
            ),
            .unresolved
        )
    }

    func testEnvironmentVariablesExpand() {
        let env = ["HOME": home]
        XCTAssertEqual(resolve("$HOME/Downloads/scotty-playbook.html", env: env),
                       file("/Users/tester/Downloads/scotty-playbook.html"))
        XCTAssertEqual(resolve("${HOME}/Downloads/scotty-playbook.html", env: env),
                       file("/Users/tester/Downloads/scotty-playbook.html"))
        XCTAssertEqual(resolve("$NOPE/Downloads/scotty-playbook.html", env: env), .unresolved)
    }

    func testMissingPathsNeverBecomeSchemelessURLs() {
        XCTAssertEqual(resolve("~/Downloads/missing.html"), .unresolved)
        XCTAssertEqual(resolve("/artifact/0-b056f7abd769"), .unresolved)
        XCTAssertEqual(resolve("   "), .unresolved)
    }

    func testSchemeURLsPassThrough() {
        XCTAssertEqual(resolve("https://claude.ai/code/x"), .url(URL(string: "https://claude.ai/code/x")!))
        XCTAssertEqual(resolve("mailto:someone@example.com"), .url(URL(string: "mailto:someone@example.com")!))
        XCTAssertEqual(resolve("vscode://file/x"), .url(URL(string: "vscode://file/x")!))
    }

    /// `URL(string:)` reports a scheme for any `token:rest`, so a single-token
    /// citation like `README:12` parses as scheme `README`. It must resolve as
    /// a path, not be sent to a nonexistent `README:` handler.
    func testSingleTokenCitationIsAPathNotAScheme() {
        XCTAssertEqual(
            resolve("README:12"),
            file("/Users/tester/projects/rai/README")
        )
        // A bare token with no line number and no matching file stays silent
        // rather than being treated as a URL.
        XCTAssertEqual(resolve("Makefile:9"), .unresolved)
    }

    func testFileURLsGoThroughTheExistenceCheck() {
        XCTAssertEqual(
            resolve("file:///Users/tester/Downloads/scotty-playbook.html"),
            file("/Users/tester/Downloads/scotty-playbook.html")
        )
        XCTAssertEqual(resolve("file:///Users/tester/Downloads/missing.html"), .unresolved)
    }

    func testCandidateOrderTriesTheRawTextFirst() {
        XCTAssertEqual(
            LinkOpenResolver.candidates(for: "a/b.swift:12;"),
            ["a/b.swift:12;", "a/b.swift:12", "a/b.swift"]
        )
        XCTAssertNil(LinkOpenResolver.strippingLineColumnSuffix(":12"))
    }
}
