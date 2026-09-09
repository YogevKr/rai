import Foundation

public struct EndpointRect: Codable, Sendable, Equatable {
    public let x, y, width, height: UInt16

    init(reader: inout EndpointBinaryReader) throws {
        x = try reader.unsigned(UInt16.self); y = try reader.unsigned(UInt16.self)
        width = try reader.unsigned(UInt16.self); height = try reader.unsigned(UInt16.self)
    }
}

public struct EndpointCell: Codable, Sendable, Equatable {
    public let symbol: String
    public let foreground, background: UInt32
    public let modifiers: UInt16
    public let skip: Bool
    public let hyperlink: UInt32?

    init(symbol: String, foreground: UInt32, background: UInt32) {
        self.symbol = symbol; self.foreground = foreground; self.background = background
        modifiers = 0; skip = false; hyperlink = nil
    }

    init(blanking cell: EndpointCell) {
        symbol = " "
        foreground = cell.background; background = cell.background
        modifiers = 0; skip = false; hyperlink = nil
    }

    init(reader: inout EndpointBinaryReader) throws {
        symbol = try reader.string()
        foreground = try reader.unsigned(UInt32.self); background = try reader.unsigned(UInt32.self)
        modifiers = try reader.unsigned(UInt16.self)
        skip = try reader.boolean()
        hyperlink = try reader.optional { try $0.unsigned(UInt32.self) }
    }
}

public struct EndpointCursor: Codable, Sendable, Equatable {
    public let x, y: UInt16
    public let visible: Bool
    public let shape: UInt8

    init(translating cursor: EndpointCursor, x: UInt16, y: UInt16) {
        self.x = cursor.x + x; self.y = cursor.y + y
        visible = cursor.visible; shape = cursor.shape
    }

    init(reader: inout EndpointBinaryReader) throws {
        x = try reader.unsigned(UInt16.self); y = try reader.unsigned(UInt16.self)
        visible = try reader.boolean(); shape = try reader.byte()
    }
}

public struct EndpointGrid: Codable, Sendable, Equatable {
    public var cells: [EndpointCell]
    public let width, height: UInt16
    public var cursor: EndpointCursor?
    public var hyperlinks: [String]

    init(reader: inout EndpointBinaryReader) throws {
        cells = try reader.array { try EndpointCell(reader: &$0) }
        width = try reader.unsigned(UInt16.self); height = try reader.unsigned(UInt16.self)
        guard cells.count == Int(width) * Int(height) else { throw HerdrEndpointError.malformed }
        cursor = try reader.optional { try EndpointCursor(reader: &$0) }
        hyperlinks = try reader.array { try $0.string() }
        _ = try reader.bytes() // Native rendering does not execute terminal graphics escape bytes.
    }
}

public struct EndpointSurfacePane: Codable, Sendable, Equatable {
    public let paneID: String
    public let contentRevision: UInt64
    public let rect, innerRect: EndpointRect
    public let scrollbarRect: EndpointRect?
    public let scroll: Scroll?
    public let focused, mouseReporting, pixelMouse, alternateScreen: Bool
    public let pixelWidth, pixelHeight: UInt32

    public struct Scroll: Codable, Sendable, Equatable {
        public let offset, maximum, rows: UInt64
    }

    init(reader: inout EndpointBinaryReader) throws {
        paneID = try reader.string(); contentRevision = try reader.integer()
        rect = try EndpointRect(reader: &reader); innerRect = try EndpointRect(reader: &reader)
        scrollbarRect = try reader.optional { try EndpointRect(reader: &$0) }
        scroll = try reader.optional { try Scroll(offset: $0.integer(), maximum: $0.integer(), rows: $0.integer()) }
        focused = try reader.boolean(); mouseReporting = try reader.boolean()
        pixelMouse = try reader.boolean(); alternateScreen = try reader.boolean()
        pixelWidth = try reader.unsigned(UInt32.self); pixelHeight = try reader.unsigned(UInt32.self)
    }
}

public struct EndpointSurfaceSplit: Codable, Sendable, Equatable {
    public let vertical: Bool
    public let position: UInt16
    public let area, hitRect: EndpointRect
    public let path: [Bool]

    init(reader: inout EndpointBinaryReader) throws {
        let direction = try reader.integer()
        guard direction <= 1 else { throw HerdrEndpointError.malformed }
        vertical = direction == 1
        position = try reader.unsigned(UInt16.self)
        area = try EndpointRect(reader: &reader); hitRect = try EndpointRect(reader: &reader)
        path = try reader.array(limit: 128) { try $0.boolean() }
    }
}

public struct EndpointPopup: Codable, Sendable, Equatable {
    public let terminalID, title: String
    public let width, height: Size?
    public let grid: EndpointGrid
    public let mouseReporting, pixelMouse: Bool
    public let pixelWidth, pixelHeight: UInt32

    public enum Size: Codable, Sendable, Equatable {
        case cells(UInt16), percent(UInt8)

        init(reader: inout EndpointBinaryReader) throws {
            switch try reader.integer() {
            case 0: self = .cells(try reader.unsigned(UInt16.self))
            case 1: self = .percent(try reader.byte())
            default: throw HerdrEndpointError.malformed
            }
        }
    }

    init(reader: inout EndpointBinaryReader) throws {
        terminalID = try reader.string(); title = try reader.string()
        width = try reader.optional { try Size(reader: &$0) }; height = try reader.optional { try Size(reader: &$0) }
        grid = try EndpointGrid(reader: &reader)
        mouseReporting = try reader.boolean(); pixelMouse = try reader.boolean()
        pixelWidth = try reader.unsigned(UInt32.self); pixelHeight = try reader.unsigned(UInt32.self)
    }
}

public struct HerdrEndpointSurface: Codable, Sendable, Equatable {
    public let bootID: String
    public let projectionRevision: UInt64
    public var revision: UInt64
    public var grid: EndpointGrid
    public var panes: [EndpointSurfacePane]
    public let splits: [EndpointSurfaceSplit]
    public let popup: EndpointPopup?
    public var graphics: EndpointGraphicsScene

    /// Remove server-drawn tracks without changing the terminal or pane geometry.
    public var presentationGrid: EndpointGrid {
        var result = grid
        for pane in panes {
            blankBorder(pane, in: &result)
            guard let rect = pane.scrollbarRect else { continue }
            let right = min(Int(grid.width), Int(rect.x) + Int(rect.width))
            let bottom = min(Int(grid.height), Int(rect.y) + Int(rect.height))
            guard Int(rect.x) < right, Int(rect.y) < bottom else { continue }
            for y in Int(rect.y)..<bottom {
                for x in Int(rect.x)..<right {
                    let index = y * Int(grid.width) + x
                    guard index < result.cells.count else { continue }
                    result.cells[index] = EndpointCell(blanking: result.cells[index])
                }
            }
        }
        return presentingPopup(over: result)
    }

    private func blankBorder(_ pane: EndpointSurfacePane, in grid: inout EndpointGrid) {
        let right = min(Int(grid.width), Int(pane.rect.x) + Int(pane.rect.width))
        let bottom = min(Int(grid.height), Int(pane.rect.y) + Int(pane.rect.height))
        guard Int(pane.rect.x) < right, Int(pane.rect.y) < bottom else { return }
        let inner = pane.innerRect
        for y in Int(pane.rect.y)..<bottom {
            for x in Int(pane.rect.x)..<right {
                guard x < Int(inner.x) || x >= Int(inner.x) + Int(inner.width)
                    || y < Int(inner.y) || y >= Int(inner.y) + Int(inner.height) else { continue }
                let index = y * Int(grid.width) + x
                if grid.cells.indices.contains(index) { grid.cells[index] = EndpointCell(blanking: grid.cells[index]) }
            }
        }
    }

    static func decode(_ data: Data) throws -> Self {
        var reader = EndpointBinaryReader(data: data)
        guard try reader.integer() == 13 else { throw HerdrEndpointError.malformed }
        let surface = try Self(bootID: reader.string(), projectionRevision: reader.integer(), revision: reader.integer(),
                               grid: EndpointGrid(reader: &reader), panes: reader.array { try EndpointSurfacePane(reader: &$0) },
                               splits: reader.array { try EndpointSurfaceSplit(reader: &$0) },
                               popup: reader.optional { try EndpointPopup(reader: &$0) },
                               graphics: EndpointGraphicsScene(reader: &reader))
        guard reader.isAtEnd else { throw HerdrEndpointError.malformed }
        return surface
    }

    mutating func applyPatch(_ data: Data) throws {
        var reader = EndpointBinaryReader(data: data)
        guard try reader.integer() == 19 else { throw HerdrEndpointError.malformed }
        let boot = try reader.string(), projection = try reader.integer(), base = try reader.integer(), next = try reader.integer()
        guard boot == bootID, projection == projectionRevision, base == revision, next > revision else {
            throw HerdrEndpointError.staleIdentity
        }
        let rows = try reader.array { reader -> (UInt16, UInt16, [EndpointCell]) in
            let x = try reader.unsigned(UInt16.self), y = try reader.unsigned(UInt16.self)
            return (x, y, try reader.array { try EndpointCell(reader: &$0) })
        }
        let updates = try reader.array { try EndpointSurfacePane(reader: &$0) }
        let cursor = try reader.optional { try EndpointCursor(reader: &$0) }
        guard reader.isAtEnd else { throw HerdrEndpointError.malformed }
        for (x, y, cells) in rows {
            guard Int(x) + cells.count <= Int(grid.width), y < grid.height else { throw HerdrEndpointError.malformed }
        }
        let known = Set(panes.map(\.paneID))
        guard updates.allSatisfy({ known.contains($0.paneID) }) else { throw HerdrEndpointError.staleIdentity }
        for (x, y, cells) in rows {
            let start = Int(y) * Int(grid.width) + Int(x)
            grid.cells.replaceSubrange(start..<(start + cells.count), with: cells)
        }
        for pane in updates { if let index = panes.firstIndex(where: { $0.paneID == pane.paneID }) { panes[index] = pane } }
        grid.cursor = cursor
        revision = next
    }
}
