import Foundation

extension HerdrEndpointSurface {
    /// The popup owns a separate terminal. Hide the tiled content while the modal terminal is active.
    func presentingPopup(over base: EndpointGrid) -> EndpointGrid {
        guard let popup, let origin = popupOrigin else { return base }
        var result = base
        let foreground = popup.grid.cells.first?.foreground ?? 0xdddddd
        let background = popup.grid.cells.first?.background ?? 0x222222
        result.cells = base.cells.map { _ in EndpointCell(symbol: " ", foreground: foreground, background: background) }
        result.hyperlinks = popup.grid.hyperlinks
        result.cursor = nil
        let width = min(Int(popup.grid.width), Int(base.width) - 2)
        let height = min(Int(popup.grid.height), Int(base.height) - 2)
        for y in -1...height {
            for x in -1...width {
                let destination = (origin.y + y) * Int(base.width) + origin.x + x
                guard result.cells.indices.contains(destination) else { continue }
                if (0..<width).contains(x), (0..<height).contains(y) {
                    let source = y * Int(popup.grid.width) + x
                    if popup.grid.cells.indices.contains(source) { result.cells[destination] = popup.grid.cells[source] }
                } else {
                    let symbol = y == -1 || y == height ? "─" : "│"
                    result.cells[destination] = EndpointCell(symbol: symbol, foreground: foreground, background: background)
                }
            }
        }
        if let cursor = popup.grid.cursor, Int(cursor.x) < width, Int(cursor.y) < height {
            result.cursor = EndpointCursor(translating: cursor, x: UInt16(origin.x), y: UInt16(origin.y))
        }
        return result
    }

    var popupOrigin: (x: Int, y: Int)? {
        guard let popup, grid.width >= 3, grid.height >= 3 else { return nil }
        let width = min(Int(popup.grid.width), Int(grid.width) - 2)
        let height = min(Int(popup.grid.height), Int(grid.height) - 2)
        return ((Int(grid.width) - width) / 2, (Int(grid.height) - height) / 2)
    }

    public var presentationGraphics: EndpointGraphicsScene {
        guard let popup, let origin = popupOrigin else {
            let placements = graphics.placements.filter {
                if case .popup = $0.asset.source { return false }
                return true
            }
            return EndpointGraphicsScene(assets: graphics.assets, placements: placements, retained: graphics.retained)
        }
        let placements = graphics.placements.compactMap { placement -> EndpointGraphicsPlacement? in
            guard case .popup(let terminal, _) = placement.asset.source, terminal == popup.terminalID,
                  UInt64(placement.x) + UInt64(placement.columns) <= UInt64(popup.grid.width),
                  UInt64(placement.y) + UInt64(placement.rows) <= UInt64(popup.grid.height) else { return nil }
            return EndpointGraphicsPlacement(translating: placement, x: UInt16(origin.x), y: UInt16(origin.y))
        }
        let keys = Set(placements.map(\.asset))
        return EndpointGraphicsScene(assets: graphics.assets.filter { keys.contains($0.key) },
                                     placements: placements, retained: graphics.retained.filter { keys.contains($0) })
    }
}
