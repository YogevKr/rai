import Foundation

/// Agents prepend a status glyph to the terminal title ("◐ Fixing tests").
/// Herdr's `terminal_title_stripped` removes the glyphs it knows, but the set
/// drifts upstream — Claude Code 2.1.228 swapped its braille busy-spinner for
/// half-circles and herdr 0.7.x still only strips "✳" — so strip again on
/// decode. The spinner also animates through its frames, and a stable stripped
/// title is what keeps sidebar rows from redrawing on every frame.
public enum AgentTitleGlyphs {
    /// Claude Code's attention marker, its half-circle busy spinner, and the
    /// braille spinner frames older versions used.
    private static let glyphs: Set<Character> = {
        var set: Set<Character> = ["✳", "✶", "◐", "◓", "◑", "◒"]
        for scalar in 0x2800...0x28FF {
            set.insert(Character(Unicode.Scalar(scalar)!))
        }
        return set
    }()

    /// Drops leading status glyphs and the whitespace after them. A glyph only
    /// counts as a status prefix when whitespace (or nothing) follows it, so a
    /// title that genuinely starts with one of these characters survives.
    /// Returns nil when nothing but glyphs remained.
    public static func strip(_ title: String?) -> String? {
        guard let title else { return nil }
        var text = Substring(title)
        while let first = text.first, glyphs.contains(first),
              text.dropFirst().first?.isWhitespace != false {
            text = text.dropFirst().drop(while: \.isWhitespace)
        }
        return text.isEmpty ? nil : String(text)
    }
}
