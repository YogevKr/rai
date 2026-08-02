import Foundation

/// A row the command palette can rank.
public protocol PaletteRankable {
    var rankID: String { get }
    /// Title first, supporting fields after. See `FuzzyField`.
    var rankFields: [FuzzyField] { get }
    var rankStatus: AgentStatus { get }
}

/// Ordering policy for the command palette.
///
/// Two different jobs, so two different orders:
///
/// - **No query** — the palette is a navigator. Most-recent-first, so ⌘K then
///   Return is alt-tab: it returns you where you just were.
/// - **A query** — the palette is a search box. Fuzzy score decides, and an
///   agent that needs you wins ties, because a blocked agent is the row you
///   most likely meant.
public enum PaletteRanking {
    /// How loudly a row asks for attention. Breaks score ties only — it never
    /// overrides a better match.
    public static func urgency(_ status: AgentStatus) -> Int {
        switch status {
        case .blocked: 3
        case .done: 2
        case .working: 1
        case .idle, .unknown: 0
        }
    }

    /// - Parameter recentIDs: visited rows, most recent first. The caller drops
    ///   the row it is already on; otherwise the top row would be where you
    ///   already are, and Return would do nothing.
    public static func ranked<Value: PaletteRankable>(
        _ values: [Value],
        query: String,
        recentIDs: [String] = []
    ) -> [Value] {
        var recencyRank: [String: Int] = [:]
        for (index, id) in recentIDs.enumerated() where recencyRank[id] == nil {
            recencyRank[id] = index
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return byRecency(values, recencyRank: recencyRank)
        }

        return values.enumerated()
            .compactMap { index, value -> (Value, Int, Int, Int, Int)? in
                guard let score = FuzzyMatcher.score(
                    query: trimmed,
                    fields: value.rankFields
                ) else { return nil }
                return (
                    value,
                    score,
                    urgency(value.rankStatus),
                    recencyRank[value.rankID] ?? Int.max,
                    index
                )
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                if lhs.2 != rhs.2 { return lhs.2 > rhs.2 }
                if lhs.3 != rhs.3 { return lhs.3 < rhs.3 }
                return lhs.4 < rhs.4
            }
            .map(\.0)
    }

    /// Visited rows first in recency order, then everything else untouched.
    /// Rows never visited keep their given order, so a fresh session still
    /// reads top-to-bottom as the sidebar does.
    private static func byRecency<Value: PaletteRankable>(
        _ values: [Value],
        recencyRank: [String: Int]
    ) -> [Value] {
        guard !recencyRank.isEmpty else { return values }
        let visited = values
            .filter { recencyRank[$0.rankID] != nil }
            .sorted { recencyRank[$0.rankID]! < recencyRank[$1.rankID]! }
        let rest = values.filter { recencyRank[$0.rankID] == nil }
        return visited + rest
    }
}
