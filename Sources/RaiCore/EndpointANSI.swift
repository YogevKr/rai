import Foundation

/// Converts semantic cells to display bytes. Cell text cannot inject terminal control sequences.
public enum EndpointANSI {
    public static func render(_ grid: EndpointGrid, previous: EndpointGrid? = nil) -> Data {
        guard grid.cells.count == Int(grid.width) * Int(grid.height) else { return Data() }
        let matchesSize = previous?.width == grid.width && previous?.height == grid.height && previous?.cells.count == grid.cells.count
        var output = "\u{1B}[?25l\u{1B}[?7l"
        if !matchesSize { output += "\u{1B}[0m\u{1B}[2J" }
        let matchesLinks = previous?.hyperlinks == grid.hyperlinks
        var style: String?
        for (index, cell) in grid.cells.enumerated() where !cell.skip {
            if matchesSize, matchesLinks, previous?.cells[index] == cell { continue }
            let width = max(1, Int(grid.width))
            output += "\u{1B}[\(index / width + 1);\(index % width + 1)H"
            let next = attributes(cell)
            if next != style { output += "\u{1B}[\(next)m"; style = next }
            let clean = String(cell.symbol.unicodeScalars.filter { $0.value >= 32 && !((127...159).contains($0.value)) })
            if let index = cell.hyperlink, Int(index) < grid.hyperlinks.count,
               let link = safeHyperlink(grid.hyperlinks[Int(index)]) {
                output += "\u{1B}]8;;\(link)\u{1B}\\"
            }
            output += clean.isEmpty ? " " : clean
            output += "\u{1B}]8;;\u{1B}\\"
        }
        output += "\u{1B}[0m"
        if let cursor = grid.cursor, cursor.visible, cursor.x < grid.width, cursor.y < grid.height {
            output += "\u{1B}[\(cursor.y + 1);\(cursor.x + 1)H\u{1B}[\(min(cursor.shape, 6)) q\u{1B}[?25h"
        }
        return Data(output.utf8)
    }

    private static func safeHyperlink(_ value: String) -> String? {
        guard value.utf8.count <= 8192,
              !value.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }) else { return nil }
        return value
    }

    private static func attributes(_ cell: EndpointCell) -> String {
        var values = ["0", color(cell.foreground, background: false), color(cell.background, background: true)]
        for bit in 0..<9 where cell.modifiers & (1 << bit) != 0 { values.append(String(bit + 1)) }
        return values.joined(separator: ";")
    }

    private static func color(_ value: UInt32, background: Bool) -> String {
        let base = background ? 48 : 38
        switch value >> 24 {
        case 1: return "\(base);5;\(value & 255)"
        case 2: return "\(base);2;\((value >> 16) & 255);\((value >> 8) & 255);\(value & 255)"
        default:
            let named = Int(value & 255)
            guard (1...16).contains(named) else { return background ? "49" : "39" }
            let foreground = named <= 8 ? 29 + named : 81 + named
            return String(foreground + (background ? 10 : 0))
        }
    }
}
