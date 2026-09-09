import CoreGraphics
import Foundation
import ImageIO

/// Feed validated images through SwiftTerm's existing Kitty renderer on both platforms.
/// Never forward server escape bytes, file paths, or terminal responses.
public struct EndpointGraphicsEncoder {
    private var identifiers: [EndpointGraphicsKey: UInt32] = [:]
    private var nextID: UInt32 = 1
    public private(set) var omittedImages = 0

    public init() {}

    public static func image(_ asset: EndpointGraphicsScene.Asset) -> CGImage? {
        guard let bytes = pixels(asset), let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        return CGImage(width: Int(asset.key.width), height: Int(asset.key.height), bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: Int(asset.key.width) * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    public mutating func render(_ scene: EndpointGraphicsScene, grid: EndpointGrid, reset: Bool = false) -> Data {
        omittedImages = 0
        if scene.placements.isEmpty, scene.retained.isEmpty, identifiers.isEmpty { return Data() }
        var output = "\u{1b}7"
        let desired = Set(scene.assets.map(\.key))
        // SwiftTerm deletes every unused image when it frees one image.
        // Reload the complete bounded scene when retiring any cached asset.
        if reset || identifiers.keys.contains(where: { !desired.contains($0) }) {
            identifiers = [:]
            nextID = 1
            output += command("a=d,d=A,q=2")
        } else {
            output += command("a=d,d=a,q=2")
        }
        for asset in scene.assets where identifiers[asset.key] == nil {
            guard nextID < UInt32.max, let bytes = Self.pixels(asset) else { continue }
            let id = nextID
            nextID += 1
            identifiers[asset.key] = id
            output += upload(bytes, key: asset.key, id: id)
        }
        var placementPixels: UInt64 = 0
        for placement in scene.placements {
            // Presentation resolves popup coordinates before rendering.
            let pixelCount = UInt64(placement.sourceWidth == 0 ? placement.asset.width : placement.sourceWidth)
                * UInt64(placement.sourceHeight == 0 ? placement.asset.height : placement.sourceHeight)
            guard pixelCount <= EndpointGraphicsCache.maximumPixels - placementPixels,
                  let id = identifiers[placement.asset], placement.columns > 0, placement.rows > 0,
                  UInt64(placement.x) + UInt64(placement.columns) <= grid.width,
                  UInt64(placement.y) + UInt64(placement.rows) <= grid.height,
                  UInt64(placement.sourceX) + UInt64(placement.sourceWidth) <= placement.asset.width,
                  UInt64(placement.sourceY) + UInt64(placement.sourceHeight) <= placement.asset.height else {
                omittedImages += 1
                continue
            }
            placementPixels += pixelCount
            output += "\u{1b}[\(Int(placement.y) + 1);\(Int(placement.x) + 1)H"
            output += command("a=p,i=\(id),p=\(placement.id),q=2,C=1,c=\(placement.columns),r=\(placement.rows),x=\(placement.sourceX),y=\(placement.sourceY),w=\(placement.sourceWidth),h=\(placement.sourceHeight),X=\(placement.xOffset),Y=\(placement.yOffset),z=\(placement.z)")
        }
        output += "\u{1b}8"
        return Data(output.utf8)
    }

    private func command(_ fields: String, payload: String = "") -> String {
        "\u{1b}_G\(fields);\(payload)\u{1b}\\"
    }

    private func upload(_ bytes: Data, key: EndpointGraphicsKey, id: UInt32) -> String {
        let encoded = Array(bytes.base64EncodedString().utf8)
        var result = ""
        for start in stride(from: 0, to: encoded.count, by: 4096) {
            let end = min(start + 4096, encoded.count)
            let fields = start == 0 ? "a=t,f=32,s=\(key.width),v=\(key.height),i=\(id),q=2," : ""
            result += command(fields + "m=\(end < encoded.count ? 1 : 0)",
                              payload: String(decoding: encoded[start..<end], as: UTF8.self))
        }
        return result
    }

    static func pixels(_ asset: EndpointGraphicsScene.Asset) -> Data? {
        let key = asset.key
        let width = Int(key.width), height = Int(key.height)
        guard width > 0, height > 0, UInt64(width) * UInt64(height) <= EndpointGraphicsCache.maximumPixels,
              asset.data.count == key.byteCount, asset.data.count <= EndpointGraphicsCache.maximumBytes else { return nil }
        let image: CGImage?
        if key.format == .png {
            guard let source = CGImageSourceCreateWithData(asset.data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == width,
                  (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == height else { return nil }
            image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        } else {
            let channels = key.format == .rgb ? 3 : 4
            guard asset.data.count == width * height * channels,
                  let provider = CGDataProvider(data: asset.data as CFData) else { return nil }
            image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: channels * 8,
                bytesPerRow: width * channels, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: channels == 3 ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
        guard let image else { return nil }
        var rgba = Data(count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? rgba : nil
    }
}
