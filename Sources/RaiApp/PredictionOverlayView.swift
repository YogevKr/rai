import AppKit

/// Paints not-yet-confirmed predicted keystrokes over a terminal pane, starting
/// at the terminal's caret cell (see `PredictiveEchoEngine`). Underlined, like
/// mosh, so unconfirmed text is honest about being a guess. Draws per-glyph on
/// the cell grid — attributed-string layout would drift off the terminal's
/// column positions.
///
/// Purely visual: never intercepts events. Rendered as a plain subview, which
/// composites fine over the default CoreGraphics terminal renderer; the
/// opt-in Metal renderer paints over subviews and would hide it (a known
/// limitation of that experimental path, alongside find-bar z-order).
final class PredictionOverlayView: NSView {
    var glyphs: [Character] = []
    var cellWidth: CGFloat = 0
    var glyphFont: NSFont = TerminalPaneView.font
    var textColor: NSColor = .textColor
    var cellBackground: NSColor = .clear

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard !glyphs.isEmpty, cellWidth > 0 else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: glyphFont,
            .foregroundColor: textColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: textColor.withAlphaComponent(0.6),
        ]
        for (index, glyph) in glyphs.enumerated() {
            let cell = NSRect(
                x: CGFloat(index) * cellWidth,
                y: 0,
                width: cellWidth,
                height: bounds.height
            )
            cellBackground.setFill()
            cell.fill()
            let text = String(glyph) as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(
                at: NSPoint(x: cell.minX, y: (bounds.height - size.height) / 2),
                withAttributes: attributes
            )
        }
    }
}
