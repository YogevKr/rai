import Foundation

/// Resolve delivery deltas before surface streams or the phone bridge coalesce frames.
public struct EndpointGraphicsCache {
    private var assets: [EndpointGraphicsKey: Data] = [:]
    static let maximumBytes = 8 * 1024 * 1024
    static let maximumPixels: UInt64 = 4 * 1024 * 1024

    public init() {}

    public mutating func resolve(_ scene: EndpointGraphicsScene) -> EndpointGraphicsScene {
        let desired = Set(scene.placements.map(\.asset) + scene.retained)
        assets = assets.filter { desired.contains($0.key) }
        for asset in scene.assets where desired.contains(asset.key) {
            assets[asset.key] = asset.data
        }
        // Prefer small assets. One oversized image must not hide neighboring images.
        let ordered = assets.sorted { $0.key.byteCount < $1.key.byteCount }
        var bytes = 0
        var pixels: UInt64 = 0
        var kept: [EndpointGraphicsScene.Asset] = []
        assets = [:]
        for (key, data) in ordered {
            let count = UInt64(key.width) * UInt64(key.height)
            guard data.count == key.byteCount, data.count <= Self.maximumBytes - bytes,
                  count > 0, count <= Self.maximumPixels - pixels else { continue }
            bytes += data.count
            pixels += count
            assets[key] = data
            kept.append(.init(key: key, data: data))
        }
        return EndpointGraphicsScene(assets: kept, placements: scene.placements, retained: scene.retained)
    }
}
