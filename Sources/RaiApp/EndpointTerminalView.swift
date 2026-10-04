import AppKit
import RaiCore
import SwiftTerm

/// Shared terminal view type used by the app-level input and scroll monitors.
final class EndpointTerminalView: EndpointMouseTerminalView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        optionAsMetaKey = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        optionAsMetaKey = false
    }

    var pasteText: ((String) -> Void)?
    var semanticKey: ((EndpointKey) -> Void)?
    var scrollRemote: ((String, UInt64) -> Void)?
    private var scrollTarget: (paneID: String, offset: UInt64)?
    private var lastScrollTime = TimeInterval.zero
    private var scrollFraction: CGFloat = 0

    func handleInterceptedScroll(_ event: NSEvent) {
        if sendMouseWheel(event) { return }
        guard let surface = endpointSurface, event.scrollingDeltaY != 0 else { return }
        let frame = getOptimalFrameSize()
        let cellWidth = frame.width / CGFloat(max(1, surface.grid.width))
        let cellHeight = frame.height / CGFloat(max(1, surface.grid.height))
        let point = convert(event.locationInWindow, from: nil)
        let row = (isFlipped ? point.y : bounds.height - point.y) / cellHeight
        let column = point.x / cellWidth
        guard let pane = surface.panes.first(where: {
            column >= CGFloat($0.innerRect.x) && column < CGFloat($0.innerRect.x) + CGFloat($0.innerRect.width)
                && row >= CGFloat($0.innerRect.y) && row < CGFloat($0.innerRect.y) + CGFloat($0.innerRect.height)
        }), let metrics = pane.scroll else { return }
        if scrollTarget?.paneID != pane.paneID || event.timestamp - lastScrollTime > 0.7 {
            scrollTarget = (pane.paneID, metrics.offset)
            scrollFraction = 0
        }
        lastScrollTime = event.timestamp
        scrollFraction += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / cellHeight : event.scrollingDeltaY * 3
        let lines = Int(scrollFraction)
        scrollFraction -= CGFloat(lines)
        guard lines != 0 else { return }
        let offset = EndpointScroll.offset(from: scrollTarget?.offset ?? metrics.offset, lines: lines, maximum: metrics.maximum)
        scrollTarget = (pane.paneID, offset)
        scrollRemote?(pane.paneID, offset)
    }

    func handleInterceptedKey(_ event: NSEvent) -> Bool {
        guard !hasMarkedText(), !event.modifierFlags.contains(.command) else { return false }
        if let key = EndpointKeyboard.key(for: event) {
            semanticKey?(key)
            return true
        }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .function])
        if modifiers.isEmpty, let text = event.characters,
           text.unicodeScalars.allSatisfy({ $0.value >= 32 && !(127...159).contains($0.value) }),
           text.unicodeScalars.contains(where: { $0.value > 127 }) {
            send(txt: text)
            return true
        }
        return false
    }

    override func paste(_ sender: Any) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        pasteText?(text)
    }

    var clipboard = EndpointClipboard()

    override func copy(_ sender: Any) {
        guard let selected = getSelection(), !selected.isEmpty else { return }
        clipboard.copy(selected)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText((string as? NSAttributedString)?.string ?? string, replacementRange: replacementRange)
    }
}
