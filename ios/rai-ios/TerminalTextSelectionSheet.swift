import SwiftUI
import SwiftTerm
import UIKit

/// A captured buffer keeps copy ranges stable while the agent continues writing.
struct TerminalTextSnapshot: Identifiable {
    let id = UUID()
    let text: String

    @MainActor
    init(terminal: TerminalView?) {
        text = terminal.map { String(decoding: $0.getBufferAsData(), as: UTF8.self) } ?? ""
        terminal?.window?.endEditing(true)
    }
}

enum TerminalLink {
    static func url(_ text: String) -> URL? {
        guard !text.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }),
              let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto", "tel", "sms"].contains(scheme) else { return nil }
        if scheme == "http" || scheme == "https" {
            guard let host = url.host, !host.isEmpty else { return nil }
        }
        return url
    }

    @MainActor
    static func open(_ text: String) {
        guard let url = url(text) else { return }
        UIApplication.shared.open(url)
    }
}

/// SwiftTerm's hover activation requires a pointer. Touch links need their own hit test.
///
/// SwiftTerm 2 keeps its `Terminal` private: the view offers copied text and
/// state, but no cell attributes, hyperlink payloads, or buffer edits. The
/// phone needs those for link taps, styled screen comparisons, and history
/// seeding, so every byte the view receives also feeds `mirror`, a private
/// emulator with the same grid and scrollback. Feed the view only through
/// `feedMirrored` and size its scrollback only through `setScrollback`;
/// a direct `feed` or `changeScrollback` desynchronizes the mirror.
class PhoneLinkTerminalView: TerminalView {
    var endpointLinkAt: ((String, CGPoint) -> Bool)?
    private var linkInteraction: TerminalLinkInteraction?
    private var mirrorStorage: TerminalMirror?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, linkInteraction == nil {
            linkInteraction = TerminalLinkInteraction(terminal: self)
        }
    }

    /// The mirrored emulator at the view's grid size.
    var mirroredTerminal: Terminal {
        syncMirrorSize().terminal
    }

    /// Resizes the mirror to the view's grid. The view resizes its terminal
    /// in `layoutSubviews` and `pinGridSize`; the mirror must follow each
    /// resize while the cells are still the same, because two resizes that
    /// cancel out (keyboard shown, then hidden) still pop and re-add rows.
    @discardableResult
    private func syncMirrorSize() -> TerminalMirror {
        let dimensions = terminalDimensions
        let mirror: TerminalMirror
        if let existing = mirrorStorage {
            mirror = existing
        } else {
            mirror = TerminalMirror(cols: dimensions.cols, rows: dimensions.rows, scrollback: mirrorScrollback)
            mirrorStorage = mirror
        }
        mirror.resize(cols: dimensions.cols, rows: dimensions.rows)
        return mirror
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        syncMirrorSize()
    }

    /// Pins the view's grid and resizes the mirror in the same step.
    func pinMirroredGridSize(cols: Int, rows: Int) {
        pinGridSize(cols: cols, rows: rows)
        syncMirrorSize()
    }

    private var mirrorScrollback: Int? = TerminalOptions.default.scrollback

    /// Feeds the view and its mirror. The parse completes before this returns.
    func feedMirrored(byteArray: ArraySlice<UInt8>) {
        let mirror = mirroredTerminal
        feed(byteArray: byteArray)
        mirror.feed(buffer: byteArray)
    }

    func feedMirrored(text: String) {
        let mirror = mirroredTerminal
        feed(text: text)
        mirror.feed(text: text)
    }

    /// Changes the scrollback of the view and its mirror together.
    func setScrollback(_ lines: Int?) {
        mirrorScrollback = lines
        changeScrollback(lines)
        mirrorStorage?.terminal.changeScrollback(lines)
    }
}

/// A `Terminal` that parses the same bytes as a view, for reads the view does not offer.
@MainActor
final class TerminalMirror {
    private let sink = OffscreenTerminalSink()
    let terminal: Terminal

    init(cols: Int, rows: Int, scrollback: Int?) {
        terminal = Terminal(
            delegate: sink,
            options: TerminalOptions(cols: max(1, cols), rows: max(1, rows), scrollback: scrollback ?? 0)
        )
        if scrollback == nil { terminal.changeScrollback(nil) }
    }

    func resize(cols: Int, rows: Int) {
        let cols = max(1, cols)
        let rows = max(1, rows)
        guard terminal.cols != cols || terminal.rows != rows else { return }
        terminal.resize(cols: cols, rows: rows)
    }
}

/// Delegate for an emulator that only renders; replies go nowhere.
final class OffscreenTerminalSink: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

@MainActor
final class TerminalLinkInteraction: NSObject, UIGestureRecognizerDelegate {
    private weak var terminal: PhoneLinkTerminalView?

    init(terminal: PhoneLinkTerminalView) {
        self.terminal = terminal
        super.init()
        let tap = UITapGestureRecognizer(target: self, action: #selector(openLink(_:)))
        tap.delegate = self
        for existing in terminal.gestureRecognizers ?? [] {
            guard let other = existing as? UITapGestureRecognizer else { continue }
            if other.numberOfTapsRequired > 1 { tap.require(toFail: other) }
            else { other.require(toFail: tap) }
        }
        terminal.addGestureRecognizer(tap)
    }

    func link(at point: CGPoint) -> String? {
        guard let terminal, terminal.bounds.contains(point), !terminal.isDecelerating, terminal.getSelectionRange() == nil else { return nil }
        let grid = terminal.terminalDimensions
        let size = terminal.getOptimalFrameSize()
        guard grid.cols > 0, grid.rows > 0, size.width > 0, size.height > 0 else { return nil }
        let column = Int(point.x / (size.width / CGFloat(grid.cols)))
        let row = Int(point.y / (size.height / CGFloat(grid.rows)))
        // The mirror holds the hyperlink payloads the view keeps private.
        guard column >= 0, column < grid.cols,
              let link = terminal.mirroredTerminal.link(at: .buffer(Position(col: column, row: row)), mode: .explicitAndImplicit),
              TerminalLink.url(link) != nil || terminal.endpointLinkAt != nil else { return nil }
        return link
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let terminal else { return false }
        return link(at: touch.location(in: terminal)) != nil
    }

    func activateLink(at point: CGPoint) {
        guard let terminal, let link = link(at: point) else { return }
        if terminal.endpointLinkAt?(link, point) == true { return }
        guard TerminalLink.url(link) != nil else { return }
        terminal.terminalDelegate?.requestOpenLink(source: terminal, link: link, params: [:])
    }

    @objc private func openLink(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let terminal else { return }
        activateLink(at: gesture.location(in: terminal))
    }
}

struct TerminalTextSelectionSheet: View {
    let snapshot: TerminalTextSnapshot
    @StateObject private var clipboard = EndpointClipboard()
    @StateObject private var selectionController = EndpointSelectionController()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SelectableTerminalText(text: snapshot.text, clipboard: clipboard, selectionController: selectionController)
                .safeAreaInset(edge: .bottom) {
                    EndpointSelectionControls(controller: selectionController)
                        .padding().background(.bar)
                }
                .overlay(alignment: .bottom) { EndpointClipboardNotice(clipboard: clipboard) }
                .navigationTitle("Select Text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                    ToolbarItem { ShareLink(item: snapshot.text) }
                }
        }
    }
}

struct SelectableTerminalText: UIViewRepresentable {
    let text: String
    var selection: NSRange? = nil
    let clipboard: EndpointClipboard
    var selectionController: EndpointSelectionController? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let view = EndpointSelectableTextView()
        view.clipboard = clipboard
        selectionController?.view = view
        view.isEditable = false
        view.isSelectable = true
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        view.dataDetectorTypes = [.link]
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        view.delegate = context.coordinator
        view.accessibilityLabel = "Terminal text"
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
        if context.coordinator.selection != selection {
            context.coordinator.selection = selection
            if let selection { view.selectedRange = selection; view.scrollRangeToVisible(selection) }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var selection: NSRange?
        func textView(_ textView: UITextView, shouldInteractWith URL: URL,
                      in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
            TerminalLink.url(URL.absoluteString) != nil
        }
    }
}
