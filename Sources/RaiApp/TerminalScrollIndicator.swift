import AppKit
import RaiCore
import SwiftTerm

/// An overlay that never participates in SwiftTerm's grid width calculation.
@MainActor
final class TerminalScrollIndicator: NSScroller {
    static func hideBuiltIn(in terminal: TerminalView) {
        terminal.subviews.compactMap { $0 as? NSScroller }.forEach { $0.isHidden = true }
        terminal.setFrameSize(terminal.frame.size)
    }

    private weak var terminal: TerminalView?
    private var dismissal: Task<Void, Never>?
    var trackingKnob = false
    var remoteScroll: PaneScroll? { didSet { refresh() } }
    var snapshotScroll: PaneScroll? {
        didSet {
            // SwiftUI can repeat an old snapshot after a newer scroll event.
            if snapshotScroll != oldValue { remoteScroll = snapshotScroll }
        }
    }
    var scrollRemote: ((Double) -> Void)?

    init(terminal: TerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)
        scrollerStyle = .overlay
        knobStyle = .light
        alphaValue = 0
        isHidden = true
        target = self
        action = #selector(scrollChanged)
        translatesAutoresizingMaskIntoConstraints = false
        terminal.addSubview(self)
        NSLayoutConstraint.activate([
            trailingAnchor.constraint(equalTo: terminal.trailingAnchor, constant: -2),
            topAnchor.constraint(equalTo: terminal.topAnchor),
            bottomAnchor.constraint(equalTo: terminal.bottomAnchor),
            widthAnchor.constraint(equalToConstant: NSScroller.scrollerWidth(
                for: .regular, scrollerStyle: .overlay))
        ])
    }

    required init?(coder: NSCoder) { nil }

    func refresh() {
        // The server can report an older offset while AppKit tracks the knob.
        guard let terminal, !trackingKnob else { return }
        if let remoteScroll {
            let maximum = max(0, remoteScroll.maxOffsetFromBottom)
            isEnabled = maximum > 0
            doubleValue = maximum > 0
                ? 1 - Double(remoteScroll.offsetFromBottom) / Double(maximum) : 1
            knobProportion = CGFloat(remoteScroll.viewportRows)
                / CGFloat(max(1, maximum + remoteScroll.viewportRows))
        } else {
            isEnabled = terminal.canScroll
            doubleValue = terminal.scrollPosition
            knobProportion = terminal.scrollThumbsize
        }
        if !isEnabled { hide() }
    }

    func noteScroll() {
        refresh()
        guard isEnabled else { return }
        dismissal?.cancel()
        alphaValue = 0.65
        isHidden = false
        guard !trackingKnob else { return }
        dismissal = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(700)) }
            catch { return }
            self?.hide()
        }
    }

    func hide() {
        dismissal?.cancel()
        dismissal = nil
        alphaValue = 0
        isHidden = true
    }

    override func mouseDown(with event: NSEvent) {
        trackingKnob = true
        noteScroll()
        super.mouseDown(with: event)
        trackingKnob = false
        noteScroll()
    }

    @objc private func scrollChanged() {
        guard let terminal else { return }
        if let remoteScroll, let scrollRemote {
            let page = Double(remoteScroll.viewportRows)
                / Double(max(1, remoteScroll.maxOffsetFromBottom))
            var position = doubleValue
            if hitPart == .decrementPage { position -= page }
            if hitPart == .incrementPage { position += page }
            doubleValue = min(1, max(0, position))
            scrollRemote(doubleValue)
            noteScroll()
            return
        }
        switch hitPart {
        case .decrementPage: terminal.scrollUp(lines: terminal.getTerminal().rows)
        case .incrementPage: terminal.scrollDown(lines: terminal.getTerminal().rows)
        case .knob: terminal.scroll(toPosition: doubleValue)
        default: break
        }
        noteScroll()
    }
}
