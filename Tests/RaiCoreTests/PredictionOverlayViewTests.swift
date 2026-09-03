#if os(macOS)
import AppKit
import XCTest

@testable import RaiCore

@MainActor
final class PredictionOverlayViewTests: XCTestCase {
    func testProductionOverlayReportsCompletedDraw() throws {
        _ = NSApplication.shared
        let overlay = PredictionOverlayView(
            frame: NSRect(x: 0, y: 0, width: 20, height: 20)
        )
        overlay.glyphs = ["x"]
        overlay.cellWidth = 20
        var drawCount = 0
        overlay.onDraw = { drawCount += 1 }

        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 20,
                pixelsHigh: 20,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        overlay.draw(overlay.bounds)
        NSGraphicsContext.restoreGraphicsState()

        XCTAssertEqual(drawCount, 1)
    }
}
#endif
