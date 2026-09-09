import Foundation

/// A plugin receives only a server-resolved link at a captured cell and content revision.
public struct EndpointPluginLinkInvocation: Codable, Equatable, Sendable, Identifiable {
    public let bootID: String
    public let paneID: String
    public let contentRevision: UInt64
    public let offset: UInt64?
    public let row: UInt16
    public let column: UInt16
    public let url: String
    public var explicit: Bool? = nil
    public var id: String { "\(paneID):\(row):\(column):\(contentRevision)" }

    public static func links(in surface: HerdrEndpointSurface) -> [Self] {
        guard surface.popup == nil else { return [] }
        var result: [Self] = []
        for pane in surface.panes {
            guard pane.contentRevision <= 9_007_199_254_740_991, (pane.scroll?.offset ?? 0) <= 9_007_199_254_740_991 else { continue }
            var seen = Set<String>()
            for row in 0..<Int(pane.innerRect.height) {
                for column in 0..<Int(pane.innerRect.width) {
                    let x = Int(pane.innerRect.x) + column
                    let y = Int(pane.innerRect.y) + row
                    guard let url = url(in: surface, x: x, y: y), seen.insert(url).inserted else { continue }
                    result.append(.init(bootID: surface.bootID, paneID: pane.paneID, contentRevision: pane.contentRevision,
                                        offset: pane.scroll?.offset, row: UInt16(row), column: UInt16(column), url: url))
                }
            }
        }
        return result
    }

    public static func capture(in surface: HerdrEndpointSurface, column: Int, row: Int,
                               expectedURL: String? = nil) -> Self? {
        let explicitURL = url(in: surface, x: column, y: row)
        guard surface.popup == nil, let url = explicitURL ?? expectedURL,
              expectedURL == nil || expectedURL == url, !url.isEmpty,
              !url.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }),
              let pane = surface.panes.first(where: {
                  column >= Int($0.innerRect.x) && column < Int($0.innerRect.x) + Int($0.innerRect.width)
                    && row >= Int($0.innerRect.y) && row < Int($0.innerRect.y) + Int($0.innerRect.height)
              }), pane.contentRevision <= 9_007_199_254_740_991,
              (pane.scroll?.offset ?? 0) <= 9_007_199_254_740_991 else { return nil }
        return .init(bootID: surface.bootID, paneID: pane.paneID, contentRevision: pane.contentRevision,
                     offset: pane.scroll?.offset, row: UInt16(row - Int(pane.innerRect.y)),
                     column: UInt16(column - Int(pane.innerRect.x)), url: url, explicit: explicitURL == nil ? false : nil)
    }

    public func validate(in surface: HerdrEndpointSurface) throws {
        guard contentRevision <= 9_007_199_254_740_991, (offset ?? 0) <= 9_007_199_254_740_991,
              bootID == surface.bootID, surface.popup == nil,
              let pane = surface.panes.first(where: { $0.paneID == paneID }), pane.contentRevision == contentRevision,
              pane.scroll?.offset == offset, row < pane.innerRect.height, column < pane.innerRect.width,
              Self.url(in: surface, x: Int(pane.innerRect.x) + Int(column), y: Int(pane.innerRect.y) + Int(row)) == (explicit == false ? nil : url) else {
            throw HerdrEndpointError.staleIdentity
        }
    }

    public var params: [String: JSONValue] {
        var result: [String: JSONValue] = ["pane_id": .string(paneID), "viewport_row": .number(Double(row)),
                                           "col": .number(Double(column)), "content_revision": .number(Double(contentRevision))]
        if let offset { result["offset_from_bottom"] = .number(Double(offset)) }
        return result
    }

    private static func url(in surface: HerdrEndpointSurface, x: Int, y: Int) -> String? {
        let grid = surface.grid
        guard x >= 0, y >= 0, x < Int(grid.width), y < Int(grid.height) else { return nil }
        let index = y * Int(grid.width) + x
        guard index < grid.cells.count, let link = grid.cells[index].hyperlink, Int(link) < grid.hyperlinks.count else { return nil }
        let value = grid.hyperlinks[Int(link)]
        guard !value.isEmpty, !value.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }) else { return nil }
        return value
    }
}
