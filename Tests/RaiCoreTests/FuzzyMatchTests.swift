import RaiCore
import XCTest

final class FuzzyMatchTests: XCTestCase {
    func testMatchesCaseInsensitiveSubsequence() {
        XCTAssertNotNil(FuzzyMatcher.score(query: "cpa", candidate: "Command Palette"))
        XCTAssertNotNil(FuzzyMatcher.score(query: "resume", candidate: "Résumé Agent"))
        XCTAssertNotNil(FuzzyMatcher.score(query: "  cpa  ", candidate: "Command Palette"))
    }

    func testRejectsNonSubsequence() {
        XCTAssertNil(FuzzyMatcher.score(query: "agentz", candidate: "agent"))
    }

    func testPrefixAndWordBoundaryBoosts() throws {
        let prefix = try XCTUnwrap(FuzzyMatcher.score(query: "cor", candidate: "core agent"))
        let boundary = try XCTUnwrap(FuzzyMatcher.score(query: "cor", candidate: "my core"))
        let scattered = try XCTUnwrap(FuzzyMatcher.score(query: "cor", candidate: "echo orbit"))

        XCTAssertGreaterThan(prefix, boundary)
        XCTAssertGreaterThan(boundary, scattered)
    }

    func testConsecutiveCharactersBeatWideGaps() throws {
        let consecutive = try XCTUnwrap(
            FuzzyMatcher.score(query: "bcd", candidate: "agent bcdef")
        )
        let scattered = try XCTUnwrap(
            FuzzyMatcher.score(query: "bcd", candidate: "agent bxxcxxd")
        )

        XCTAssertGreaterThan(consecutive, scattered)
    }

    func testRankedFiltersAndOrdersMatches() {
        let values = ["my core", "cobalt runner", "echo orbit", "unrelated"]

        XCTAssertEqual(
            FuzzyMatcher.ranked(values, query: "cor") { $0 },
            ["cobalt runner", "my core", "echo orbit"]
        )
    }

    func testEmptyQueryPreservesIndexOrder() {
        XCTAssertEqual(
            FuzzyMatcher.ranked(["second", "first"], query: "  ") { $0 },
            ["second", "first"]
        )
    }
}
