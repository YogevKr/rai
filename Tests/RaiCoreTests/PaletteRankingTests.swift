import XCTest
@testable import RaiCore

private struct Row: PaletteRankable, Equatable {
    let rankID: String
    let rankFields: [FuzzyField]
    let rankStatus: AgentStatus

    init(_ id: String, fields: [FuzzyField]? = nil, status: AgentStatus = .idle) {
        rankID = id
        rankFields = fields ?? [FuzzyField(id)]
        rankStatus = status
    }
}

final class PaletteRankingTests: XCTestCase {
    // MARK: - Empty query: a navigator

    func testEmptyQueryPutsTheMostRecentRowFirst() {
        let rows = [Row("alpha"), Row("beta"), Row("gamma")]
        let ranked = PaletteRanking.ranked(rows, query: "", recentIDs: ["gamma", "alpha"])
        XCTAssertEqual(ranked.map(\.rankID), ["gamma", "alpha", "beta"])
    }

    func testEmptyQueryKeepsUnvisitedRowsInTheGivenOrder() {
        let rows = [Row("alpha"), Row("beta"), Row("gamma")]
        let ranked = PaletteRanking.ranked(rows, query: "", recentIDs: [])
        XCTAssertEqual(ranked.map(\.rankID), ["alpha", "beta", "gamma"])
    }

    func testEmptyQueryIgnoresRecentIDsThatNoLongerExist() {
        let rows = [Row("alpha"), Row("beta")]
        let ranked = PaletteRanking.ranked(rows, query: "", recentIDs: ["closed", "beta"])
        XCTAssertEqual(ranked.map(\.rankID), ["beta", "alpha"])
    }

    func testWhitespaceOnlyQueryCountsAsEmpty() {
        let rows = [Row("alpha"), Row("beta")]
        let ranked = PaletteRanking.ranked(rows, query: "   ", recentIDs: ["beta"])
        XCTAssertEqual(ranked.first?.rankID, "beta")
    }

    // MARK: - Query: a search box

    func testQueryDropsRowsThatDoNotMatch() {
        let rows = [Row("alpha"), Row("beta")]
        let ranked = PaletteRanking.ranked(rows, query: "alp", recentIDs: [])
        XCTAssertEqual(ranked.map(\.rankID), ["alpha"])
    }

    func testScoreBeatsRecency() {
        // Recency must not drag a worse match above a better one, or the
        // palette stops being a search box the moment you type.
        let rows = [Row("curator"), Row("condition-curator")]
        let ranked = PaletteRanking.ranked(
            rows,
            query: "curator",
            recentIDs: ["condition-curator"]
        )
        XCTAssertEqual(ranked.first?.rankID, "curator")
    }

    func testKebabInitialsMatch() {
        // Word-separator bonuses make "ran" find "red-alerts-notifier". This is
        // deliberate: typing segment initials is how people search kebab names.
        let rows = [Row("red-alerts-notifier"), Row("unrelated")]
        let ranked = PaletteRanking.ranked(rows, query: "ran", recentIDs: [])
        XCTAssertEqual(ranked.first?.rankID, "red-alerts-notifier")
    }

    func testBlockedWinsATieOnScore() {
        let rows = [
            Row("api", fields: [FuzzyField("api")], status: .idle),
            Row("api-2", fields: [FuzzyField("api")], status: .blocked),
        ]
        let ranked = PaletteRanking.ranked(rows, query: "api", recentIDs: [])
        XCTAssertEqual(ranked.first?.rankID, "api-2")
    }

    func testUrgencyOrdersBlockedAboveDoneAboveWorkingAboveIdle() {
        XCTAssertGreaterThan(
            PaletteRanking.urgency(.blocked),
            PaletteRanking.urgency(.done)
        )
        XCTAssertGreaterThan(
            PaletteRanking.urgency(.done),
            PaletteRanking.urgency(.working)
        )
        XCTAssertGreaterThan(
            PaletteRanking.urgency(.working),
            PaletteRanking.urgency(.idle)
        )
        XCTAssertEqual(PaletteRanking.urgency(.unknown), PaletteRanking.urgency(.idle))
    }

    func testRecencyBreaksATieOnScoreAndUrgency() {
        let rows = [
            Row("api", fields: [FuzzyField("api")]),
            Row("api-2", fields: [FuzzyField("api")]),
        ]
        let ranked = PaletteRanking.ranked(rows, query: "api", recentIDs: ["api-2"])
        XCTAssertEqual(ranked.first?.rankID, "api-2")
    }

    // MARK: - Multi-field matching

    func testASecondaryFieldMakesARowFindable() {
        // "the codex agent in curator" — the title alone would never match.
        let row = Row(
            "tab:1",
            fields: [FuzzyField("codex"), FuzzyField("condition-curator", weight: 65)]
        )
        let ranked = PaletteRanking.ranked([row], query: "curator", recentIDs: [])
        XCTAssertEqual(ranked.map(\.rankID), ["tab:1"])
    }

    func testATitleHitOutranksTheSameHitInAWeightedField() {
        let title = Row("a", fields: [FuzzyField("curator")])
        let secondary = Row("b", fields: [FuzzyField("zzzz"), FuzzyField("curator", weight: 65)])
        let ranked = PaletteRanking.ranked([secondary, title], query: "curator", recentIDs: [])
        XCTAssertEqual(ranked.map(\.rankID), ["a", "b"])
    }

    func testPathFieldMakesADirectoryQueryWork() {
        let row = Row(
            "w1",
            fields: [FuzzyField("Space 1"), FuzzyField("/Users/y/repos/nanoclaw", weight: 45)]
        )
        let ranked = PaletteRanking.ranked([row], query: "nanoclaw", recentIDs: [])
        XCTAssertEqual(ranked.map(\.rankID), ["w1"])
    }

    func testEmptyFieldsNeverMatch() {
        let row = Row("blank", fields: [FuzzyField("")])
        XCTAssertTrue(PaletteRanking.ranked([row], query: "x", recentIDs: []).isEmpty)
    }
}

final class FuzzyFieldScoreTests: XCTestCase {
    func testBestFieldWins() {
        let score = FuzzyMatcher.score(
            query: "abc",
            fields: [FuzzyField("zzz abc"), FuzzyField("abc")]
        )
        let direct = FuzzyMatcher.score(query: "abc", candidate: "abc")
        XCTAssertEqual(score, direct)
    }

    func testWeightScalesTheScoreDown() {
        let full = FuzzyMatcher.score(query: "abc", fields: [FuzzyField("abc")])
        let half = FuzzyMatcher.score(query: "abc", fields: [FuzzyField("abc", weight: 50)])
        XCTAssertNotNil(full)
        XCTAssertNotNil(half)
        XCTAssertLessThan(half!, full!)
    }

    func testNoMatchingFieldReturnsNil() {
        XCTAssertNil(FuzzyMatcher.score(query: "zzz", fields: [FuzzyField("abc")]))
    }

    func testNoFieldsReturnsNil() {
        XCTAssertNil(FuzzyMatcher.score(query: "abc", fields: []))
    }
}
