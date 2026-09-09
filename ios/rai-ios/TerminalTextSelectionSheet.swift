import SwiftUI
import SwiftTerm
import UIKit

/// A captured buffer keeps copy ranges stable while the agent continues writing.
struct TerminalTextSnapshot: Identifiable {
    let id = UUID()
    let text: String

    @MainActor
    init(terminal: TerminalView?) {
        text = terminal.map { String(decoding: $0.getTerminal().getBufferAsData(), as: UTF8.self) } ?? ""
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
class PhoneLinkTerminalView: TerminalView {
    var endpointLinkAt: ((String, CGPoint) -> Bool)?
    private var linkInteraction: TerminalLinkInteraction?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, linkInteraction == nil {
            linkInteraction = TerminalLinkInteraction(terminal: self)
        }
    }
}

@MainActor
final class TerminalLinkInteraction: NSObject, UIGestureRecognizerDelegate {
    private weak var terminal: TerminalView?

    init(terminal: TerminalView) {
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
        let buffer = terminal.getTerminal()
        let size = terminal.getOptimalFrameSize()
        guard buffer.cols > 0, buffer.rows > 0, size.width > 0, size.height > 0 else { return nil }
        let column = Int(point.x / (size.width / CGFloat(buffer.cols)))
        let row = Int(point.y / (size.height / CGFloat(buffer.rows)))
        guard column >= 0, column < buffer.cols,
              let link = buffer.link(at: .buffer(Position(col: column, row: row)), mode: .explicitAndImplicit),
              TerminalLink.url(link) != nil || (terminal as? PhoneLinkTerminalView)?.endpointLinkAt != nil else { return nil }
        return link
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let terminal else { return false }
        return link(at: touch.location(in: terminal)) != nil
    }

    func activateLink(at point: CGPoint) {
        guard let terminal, let link = link(at: point) else { return }
        if (terminal as? PhoneLinkTerminalView)?.endpointLinkAt?(link, point) == true { return }
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
