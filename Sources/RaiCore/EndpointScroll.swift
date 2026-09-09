import CoreGraphics
import Foundation

public enum EndpointScroll {
    /// JSONValue uses Double. Keep offsets within its exact integer range.
    public static let maximumOffset: UInt64 = 9_007_199_254_740_991

    public static func offset(from base: UInt64, lines: Int, maximum: UInt64) -> UInt64 {
        let limit = min(maximum, maximumOffset)
        let current = min(base, limit)
        if lines >= 0 { return current + min(UInt64(lines), limit - current) }
        return current - min(UInt64(lines.magnitude), current)
    }

    /// Unit coordinates keep overlay placement independent of pixel density.
    public static func thumb(pane: EndpointSurfacePane, grid: EndpointGrid) -> CGRect? {
        guard let scroll = pane.scroll, scroll.maximum > 0, grid.width > 0, grid.height > 0 else { return nil }
        let rect = pane.innerRect
        let height = Double(rect.height)
        guard rect.width > 0, height > 0 else { return nil }
        let maximum = Double(scroll.maximum), rows = Double(scroll.rows)
        let length = min(height, max(1, height * rows / (maximum + rows)))
        let progress = 1 - Double(min(scroll.offset, scroll.maximum)) / maximum
        return CGRect(x: (Double(rect.x) + Double(rect.width)) / Double(grid.width),
                      y: (Double(rect.y) + (height - length) * progress) / Double(grid.height),
                      width: 0, height: length / Double(grid.height))
    }
}
