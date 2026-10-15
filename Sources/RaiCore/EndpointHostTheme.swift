import Foundation

/// Actual host terminal colors, independent of Herdr's decoration theme.
public struct EndpointHostTheme: Equatable, Sendable {
    public enum Appearance: UInt8, Sendable { case dark = 0, light = 1 }
    public let foreground: UInt32
    public let background: UInt32
    public let palette: [UInt32]
    public let appearance: Appearance

    /// Colors use 0xRRGGBB. Supply all 256 terminal palette entries.
    public init(foreground: UInt32, background: UInt32, palette: [UInt32], appearance: Appearance) throws {
        guard palette.count == 256, ([foreground, background] + palette).allSatisfy({ $0 <= 0xffffff }) else {
            throw HerdrEndpointError.malformed
        }
        self.foreground = foreground
        self.background = background
        self.palette = palette
        self.appearance = appearance
    }

    func frames(previous: Self?) -> [Data] {
        let appearanceFrame = Data([17, 2, appearance.rawValue])
        var frames: [Data] = previous == nil ? [appearanceFrame] : []
        for (kind, value, old) in [(UInt8(0), foreground, previous?.foreground), (1, background, previous?.background)] {
            if value != old {
                var frame = Data([17, 0, kind])
                Self.appendColor(value, to: &frame)
                frames.append(frame)
            }
        }
        let changed = palette.indices.filter { previous?.palette[$0] != palette[$0] }
        if !changed.isEmpty {
            var frame = Data([17, 1])
            HerdrEndpointWire.appendInteger(UInt64(changed.count), to: &frame)
            for index in changed {
                frame.append(UInt8(index))
                Self.appendColor(palette[index], to: &frame)
            }
            frames.append(frame)
        }
        // New colors must reach pane queries before an appearance change triggers those queries.
        if let previous, previous.appearance != appearance { frames.append(appearanceFrame) }
        return frames
    }

    private static func appendColor(_ value: UInt32, to frame: inout Data) {
        frame.append(contentsOf: [UInt8(value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }
}
