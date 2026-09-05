import Foundation

/// Splits a recent pane read from the visible rows in the same revision.
public enum PaneScrollback {
    public static func payload(recent: String, visible: String, viewportRows: Int) -> Data {
        // Herdr omits empty rows at the bottom of both reads. Dropping the
        // nominal grid height also drops history whenever the cursor leaves
        // blank rows below the last printed line.
        let screenRows = min(max(0, viewportRows), lines(visible).count)
        let history = lines(recent).dropLast(screenRows)
        guard !history.isEmpty else { return Data() }
        return Data((history.joined(separator: "\n") + "\n\u{1B}[0m").utf8)
    }

    private static func lines(_ text: String) -> [String] {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }
}
