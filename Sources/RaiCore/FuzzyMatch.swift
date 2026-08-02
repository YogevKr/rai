import Foundation

/// One searchable field of a row, and how much a hit there is worth.
///
/// A palette row is more than its title: an agent also carries its space and
/// its checkout path. Matching only the title makes "the codex in curator"
/// unfindable. Weights keep the title ahead of the supporting fields, so a
/// title hit still outranks a path hit of the same shape.
public struct FuzzyField: Equatable, Sendable {
    public let text: String
    /// Percent of the raw score kept for a hit here. 100 keeps all of it.
    public let weight: Int

    public init(_ text: String, weight: Int = 100) {
        self.text = text
        self.weight = weight
    }
}

public enum FuzzyMatcher {
    /// Scores a case-insensitive subsequence match. Prefixes, word boundaries,
    /// and consecutive characters rank ahead of scattered matches.
    public static func score(query: String, candidate: String) -> Int? {
        let needle = Array(
            normalize(query.trimmingCharacters(in: .whitespacesAndNewlines))
        )
        let haystack = Array(normalize(candidate))
        guard !needle.isEmpty else { return 0 }
        guard needle.count <= haystack.count else { return nil }

        var matchedOffsets: [Int] = []
        var searchStart = 0
        for character in needle {
            guard let offset = haystack[searchStart...].firstIndex(of: character) else {
                return nil
            }
            matchedOffsets.append(offset)
            searchStart = offset + 1
        }

        var result = needle.count * 10
        if matchedOffsets.first == 0 {
            result += 100
        }

        for (index, offset) in matchedOffsets.enumerated() {
            if offset == 0 || isWordSeparator(haystack[offset - 1]) {
                result += 35
            }
            if index > 0 {
                let gap = offset - matchedOffsets[index - 1] - 1
                if gap == 0 {
                    result += 20
                } else {
                    result -= gap * 2
                }
            }
        }

        result -= matchedOffsets[0]
        result -= max(0, haystack.count - needle.count) / 4
        return result
    }

    /// Best weighted score across several fields, or nil when none match.
    public static func score(query: String, fields: [FuzzyField]) -> Int? {
        var best: Int?
        for field in fields {
            guard !field.text.isEmpty,
                  let raw = score(query: query, candidate: field.text) else { continue }
            let weighted = raw * field.weight / 100
            if best == nil || weighted > best! { best = weighted }
        }
        return best
    }

    public static func ranked<Value>(
        _ values: [Value],
        query: String,
        text: (Value) -> String
    ) -> [Value] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return values
        }

        return values.enumerated()
            .compactMap { index, value -> (Value, Int, Int, String)? in
                let label = text(value)
                guard let score = score(query: query, candidate: label) else { return nil }
                return (value, score, index, normalize(label))
            }
            .sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                if $0.3 != $1.3 { return $0.3 < $1.3 }
                return $0.2 < $1.2
            }
            .map(\.0)
    }

    private static func normalize(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func isWordSeparator(_ character: Character) -> Bool {
        character.isWhitespace || "-_./:".contains(character)
    }
}
