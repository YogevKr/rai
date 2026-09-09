import Foundation

/// Popup links cannot use the pane-only plugin API. Capture their displayed target for browser opening.
public struct EndpointPopupLinkInvocation: Sendable, Identifiable {
    public let id = UUID()
    public let bootID, terminalID, url: String
    public let surfaceRevision, projectionRevision: UInt64
    public let column, row: Int

    public static func capture(in surface: HerdrEndpointSurface, column: Int, row: Int,
                               expectedURL: String) -> Self? {
        guard let popup = surface.popup, let origin = surface.popupOrigin,
              !expectedURL.isEmpty, expectedURL.utf8.count <= 8192,
              !expectedURL.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }) else { return nil }
        let x = column - origin.x, y = row - origin.y
        guard x >= 0, y >= 0,
              x < min(Int(popup.grid.width), Int(surface.grid.width) - 2),
              y < min(Int(popup.grid.height), Int(surface.grid.height) - 2),
              matches(expectedURL, in: popup.grid, column: x, row: y) else { return nil }
        return Self(bootID: surface.bootID, terminalID: popup.terminalID, url: expectedURL,
                    surfaceRevision: surface.revision, projectionRevision: surface.projectionRevision,
                    column: column, row: row)
    }

    public func validate(in surface: HerdrEndpointSurface) throws {
        guard bootID == surface.bootID, terminalID == surface.popup?.terminalID,
              surfaceRevision == surface.revision, projectionRevision == surface.projectionRevision,
              Self.capture(in: surface, column: column, row: row, expectedURL: url) != nil else {
            throw HerdrEndpointError.staleIdentity
        }
    }

    private static func matches(_ url: String, in grid: EndpointGrid, column: Int, row: Int) -> Bool {
        let start = row * Int(grid.width), index = start + column
        guard grid.cells.indices.contains(index), start + Int(grid.width) <= grid.cells.count else { return false }
        if let hyperlink = grid.cells[index].hyperlink {
            return Int(hyperlink) < grid.hyperlinks.count && grid.hyperlinks[Int(hyperlink)] == url
        }
        let cells = grid.cells[start..<(start + Int(grid.width))]
        let text = cells.map { $0.skip ? "" : $0.symbol }.joined()
        let offset = cells.prefix(column).reduce(0) { $0 + ($1.skip ? 0 : $1.symbol.utf16.count) }
        let selected = grid.cells[index].skip ? max(0, offset - 1) : offset
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return false }
        return detector.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)).contains {
            NSLocationInRange(selected, $0.range) && (text as NSString).substring(with: $0.range) == url
        }
    }
}
