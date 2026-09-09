import Foundation

public struct EndpointGraphicsKey: Codable, Sendable, Hashable {
    public enum Source: Codable, Sendable, Hashable {
        case pane(String, UInt32), popup(String, UInt32), layer(String, String)
    }
    public enum Format: UInt64, Codable, Sendable { case rgb, rgba, png }
    public let source: Source
    public let width, height: UInt32
    public let format: Format
    public let byteCount, fingerprint: UInt64

    init(reader: inout EndpointBinaryReader) throws {
        switch try reader.integer() {
        case 0:
            let target = try reader.integer(), id = try reader.string(), image = try reader.unsigned(UInt32.self)
            guard target <= 1 else { throw HerdrEndpointError.malformed }
            source = target == 0 ? .pane(id, image) : .popup(id, image)
        case 1: source = .layer(try reader.string(), try reader.string())
        default: throw HerdrEndpointError.malformed
        }
        width = try reader.unsigned(UInt32.self); height = try reader.unsigned(UInt32.self)
        guard let format = Format(rawValue: try reader.integer()) else { throw HerdrEndpointError.malformed }
        self.format = format
        byteCount = try reader.integer(); fingerprint = try reader.integer()
        guard width > 0, height > 0, byteCount <= 32 * 1024 * 1024 else { throw HerdrEndpointError.limitExceeded }
    }
}

public struct EndpointGraphicsPlacement: Codable, Sendable, Equatable {
    public let asset: EndpointGraphicsKey
    public let id: UInt32
    public let x, y: UInt16
    public let columns, rows, sourceX, sourceY, sourceWidth, sourceHeight, xOffset, yOffset: UInt32
    public let z: Int32
    public let scrollbackOffset: UInt32

    init(translating source: EndpointGraphicsPlacement, x: UInt16, y: UInt16) {
        asset = source.asset; id = source.id
        self.x = UInt16(clamping: UInt32(source.x) + UInt32(x))
        self.y = UInt16(clamping: UInt32(source.y) + UInt32(y))
        columns = source.columns; rows = source.rows
        sourceX = source.sourceX; sourceY = source.sourceY
        sourceWidth = source.sourceWidth; sourceHeight = source.sourceHeight
        xOffset = source.xOffset; yOffset = source.yOffset
        z = source.z; scrollbackOffset = source.scrollbackOffset
    }

    init(reader: inout EndpointBinaryReader) throws {
        asset = try EndpointGraphicsKey(reader: &reader)
        id = try reader.unsigned(UInt32.self); x = try reader.unsigned(UInt16.self); y = try reader.unsigned(UInt16.self)
        columns = try reader.unsigned(UInt32.self); rows = try reader.unsigned(UInt32.self)
        sourceX = try reader.unsigned(UInt32.self); sourceY = try reader.unsigned(UInt32.self)
        sourceWidth = try reader.unsigned(UInt32.self); sourceHeight = try reader.unsigned(UInt32.self)
        xOffset = try reader.unsigned(UInt32.self); yOffset = try reader.unsigned(UInt32.self)
        let zigzag = try reader.unsigned(UInt32.self)
        z = Int32(bitPattern: (zigzag >> 1) ^ (0 &- (zigzag & 1)))
        scrollbackOffset = try reader.unsigned(UInt32.self)
    }
}

public struct EndpointGraphicsScene: Codable, Sendable, Equatable {
    public struct Asset: Codable, Sendable, Equatable {
        public let key: EndpointGraphicsKey
        public let data: Data
    }
    public let assets: [Asset]
    public let placements: [EndpointGraphicsPlacement]
    public let retained: [EndpointGraphicsKey]

    public func excludingAssets(_ delivered: Set<EndpointGraphicsKey>) -> Self {
        Self(assets: assets.filter { !delivered.contains($0.key) }, placements: placements, retained: retained)
    }

    init(assets: [Asset], placements: [EndpointGraphicsPlacement], retained: [EndpointGraphicsKey]) {
        self.assets = assets; self.placements = placements; self.retained = retained
    }

    init(reader: inout EndpointBinaryReader) throws {
        assets = try reader.array(limit: 4096) { reader in
            let key = try EndpointGraphicsKey(reader: &reader), bytes = try reader.bytes()
            guard bytes.count == key.byteCount else { throw HerdrEndpointError.malformed }
            return Asset(key: key, data: bytes)
        }
        placements = try reader.array(limit: 16_384) { try EndpointGraphicsPlacement(reader: &$0) }
        retained = try reader.array(limit: 4096) { try EndpointGraphicsKey(reader: &$0) }
    }
}
