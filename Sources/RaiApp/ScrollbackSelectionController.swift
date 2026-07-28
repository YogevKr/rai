import AppKit
import RaiCore
import SwiftTerm

/// Drives a drag-selection past the pane's edge into herdr-side scrollback.
///
/// The pane terminal is an alt-screen viewport (`herdr terminal attach`), so
/// there is nothing local to scroll into. Instead, when the pointer crosses the
/// top/bottom edge with the button down, this controller:
///
///  1. Probes whether the pane host-scrolls: it injects one SGR wheel report
///     into the attach stream (herdr routes it to its own scrollback for panes
///     without app mouse reporting) and watches the pane's scroll offset.
///  2. While the pointer is held past the edge, keeps injecting wheel steps —
///     the pane visibly scrolls — and after each step reads the revealed page
///     with `pane.read` and the exact offset from the snapshot.
///  3. Tracks the selection in absolute buffer coordinates
///     (`ScrollbackSelectionModel`), repaints the visible highlight through the
///     SwiftTerm fork's `setSelectionRange`, and assembles the final copy from
///     the pages the user actually scrolled through.
///
/// Panes whose app owns the mouse (Claude) fail the probe and keep today's
/// visible-only selection; extending herdr's attach routing for those is
/// proposed upstream (ogulcancelik/herdr#1978).
@MainActor
final class ScrollbackSelectionController {
    enum EdgeDirection { case up, down }

    weak var view: FocusAwareTerminalView?
    var paneID: String?

    private static let wheelUp = "\u{1b}[<64;1;1M"
    private static let wheelDown = "\u{1b}[<65;1;1M"

    private let client = HerdrClient()
    private var model = ScrollbackSelectionModel()
    private var timer: Timer?
    private var edge: EdgeDirection?
    private var distance: CGFloat = 0
    private(set) var engaged = false
    private var probing = false
    private var probeFailed = false
    private var lastScroll: PaneScroll?
    private var tickBusy = false
    private var pointerCol = 0
    private var lastAppliedHighlight: (Int, Int, Int, Int)?

    // Sticky selection across scrolling: after mouseUp the selection must stay
    // glued to its TEXT, not its screen rows. For host-scrollable panes we
    // re-derive the visible highlight from absolute coordinates on every
    // scroll; for app-scrolled panes (Claude owns the wheel) offsets never
    // move, so we verify the text under the highlight and clear when it no
    // longer matches — an honest clear beats a highlight on the wrong text.
    private var stickyText: String?
    private var stickyStart: Position?
    private var stickyEnd: Position?
    private var wheelReconcileTask: Task<Void, Never>?

    // MARK: gesture lifecycle

    func mouseDown() {
        stopTimer()
        wheelReconcileTask?.cancel()
        engaged = false
        probing = false
        probeFailed = false
        model.reset()
        lastScroll = nil
        edge = nil
        clearSticky()
    }

    /// Pointer moved during a drag. `edge` is non-nil while the pointer is past
    /// the top/bottom edge; `visibleRow/Col` is the pointer's cell (clamped to
    /// the viewport).
    func dragUpdate(edge: EdgeDirection?, distance: CGFloat, visibleRow: Int, visibleCol: Int) {
        self.distance = distance
        self.pointerCol = visibleCol
        if engaged, edge == nil, let scroll = lastScroll {
            // Pointer back inside: the head follows it directly.
            model.extendHead(visibleRow: visibleRow, col: visibleCol, scroll: scroll)
            applyHighlight()
        }
        guard edge != self.edge else { return }
        self.edge = edge
        if edge == nil {
            stopTimer()
            return
        }
        if engaged {
            startTimer()
        } else if !probing, !probeFailed {
            probe(edge: edge!)
        }
    }

    /// Ends the gesture. Returns the assembled text when the engine owned an
    /// extended selection (for copy-on-select); with copy-on-select the model
    /// resets, otherwise it stays for an explicit ⌘C.
    func finishGesture(copyOnSelect: Bool) -> String? {
        stopTimer()
        edge = nil
        guard engaged else { return nil }
        let text = model.assembledText()
        if copyOnSelect {
            clear()
        }
        return text
    }

    var hasExtendedSelection: Bool { engaged && model.isActive }

    /// Records a finalized visible-only selection so scrolling can keep it
    /// anchored to content. (Engaged selections already carry the model.)
    func captureStickySelection() {
        guard !engaged, let view, let range = view.getSelectionRange(),
              let paneID else { return }
        stickyText = view.getSelection()
        stickyStart = range.start
        stickyEnd = range.end
        Task { [weak self] in
            guard let self else { return }
            guard let scroll = try? await self.paneScroll(paneID) else { return }
            // Anchor in absolute coordinates for offset-based tracking.
            var m = ScrollbackSelectionModel()
            m.begin(anchorVisibleRow: range.start.row, col: range.start.col, scroll: scroll)
            m.extendHead(visibleRow: range.end.row, col: range.end.col, scroll: scroll)
            self.model = m
            self.lastScroll = scroll
            self.lastAppliedHighlight = nil
        }
    }

    /// Called for every wheel event over the pane; reconciles the highlight
    /// with wherever the content actually moved, after the scroll settles.
    func noteWheel() {
        guard model.isActive || stickyText != nil else { return }
        wheelReconcileTask?.cancel()
        wheelReconcileTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard !Task.isCancelled else { return }
            await self?.reconcileAfterScroll()
        }
    }

    private func reconcileAfterScroll() async {
        guard let view, let paneID else { return }
        guard let scroll = try? await self.paneScroll(paneID) else { return }
        if model.isActive, let previous = lastScroll {
            if scroll != previous {
                // Host scrolled (or output appended): recompute the visible
                // slice from absolute coordinates.
                lastScroll = scroll
                lastAppliedHighlight = nil
                if let hl = model.visibleHighlight(scroll: scroll) {
                    view.setSelectionRange(
                        start: Position(col: hl.startCol, row: hl.startRow),
                        end: Position(col: hl.endCol, row: hl.endRow)
                    )
                } else if view.selectionActive {
                    // Scrolled out of view: hide the highlight but keep the
                    // model so scrolling back restores it (and ⌘C still works).
                    view.selectNone()
                }
                return
            }
        }
        // Offsets unchanged — if the app scrolled its own viewport (Claude),
        // the grid changed under a screen-anchored highlight. Verify.
        if let text = stickyText, let start = stickyStart, let end = stickyEnd,
           view.selectionActive {
            let current = view.getTerminal().getText(start: start, end: end)
            if current != text {
                view.selectNone()
                clearSticky()
            }
        }
    }

    private func clearSticky() {
        stickyText = nil
        stickyStart = nil
        stickyEnd = nil
    }

    func assembledText() -> String? { model.assembledText() }

    func clear() {
        stopTimer()
        model.reset()
        engaged = false
    }

    // MARK: internals

    private func probe(edge: EdgeDirection) {
        guard let paneID, view != nil else {
            probeFailed = true
            return
        }
        probing = true
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let before = try await self.paneScroll(paneID),
                      before.maxOffsetFromBottom > 0 || edge == .down else {
                    self.probing = false
                    self.probeFailed = true
                    return
                }
                // Capture the anchor + the current page BEFORE moving anything.
                let anchor = self.view?.getSelectionRange()?.start
                let page0 = try await self.client.readPane(
                    paneID: paneID, format: "ansi", stripANSI: true
                )
                self.inject(edge == .up ? Self.wheelUp : Self.wheelDown)
                try await Task.sleep(nanoseconds: 150_000_000)
                guard let after = try await self.paneScroll(paneID),
                      after.offsetFromBottom != before.offsetFromBottom else {
                    // The wheel went to the pane's app (mouse-mode, e.g.
                    // Claude): no host scroll. Keep visible-only selection.
                    self.probing = false
                    self.probeFailed = true
                    return
                }
                var m = ScrollbackSelectionModel()
                m.ingest(pageText: page0.text, scroll: before)
                let anchorPos = anchor ?? Position(col: 0, row: before.viewportRows - 1)
                m.begin(anchorVisibleRow: anchorPos.row, col: anchorPos.col, scroll: before)
                let page1 = try await self.client.readPane(
                    paneID: paneID, format: "ansi", stripANSI: true
                )
                m.ingest(pageText: page1.text, scroll: after)
                m.extendHead(
                    visibleRow: edge == .up ? 0 : after.viewportRows - 1,
                    col: self.pointerCol,
                    scroll: after
                )
                self.model = m
                self.lastScroll = after
                self.engaged = true
                self.probing = false
                // The engine owns the gesture from here; SwiftTerm's own
                // selection auto-scroll timer (started by the pre-engage
                // drags) would keep re-extending toward a stale pointer.
                self.view?.cancelSelectionAutoScroll()
                self.applyHighlight()
                if self.edge != nil { self.startTimer() }
            } catch {
                self.probing = false
                self.probeFailed = true
            }
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        // .common so it fires during mouse tracking, same trick as SwiftTerm's
        // own selection auto-scroll timer.
        let t = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard engaged, !tickBusy, let edge, let paneID else { return }
        tickBusy = true
        // Farther past the edge = faster, like herdr's own selection drag.
        let steps = 1 + min(3, Int(distance / 40))
        for _ in 0..<steps {
            inject(edge == .up ? Self.wheelUp : Self.wheelDown)
        }
        Task { [weak self] in
            guard let self else { return }
            defer { self.tickBusy = false }
            do {
                try await Task.sleep(nanoseconds: 60_000_000)
                guard let scroll = try await self.paneScroll(paneID) else { return }
                let page = try await self.client.readPane(
                    paneID: paneID, format: "ansi", stripANSI: true
                )
                self.model.ingest(pageText: page.text, scroll: scroll)
                self.model.extendHead(
                    visibleRow: edge == .up ? 0 : scroll.viewportRows - 1,
                    col: self.pointerCol,
                    scroll: scroll
                )
                self.lastScroll = scroll
                self.view?.cancelSelectionAutoScroll()
                self.applyHighlight()
            } catch {
                // Transient RPC failure: skip this tick, keep the gesture.
            }
        }
    }

    private func applyHighlight() {
        guard let view, let scroll = lastScroll,
              let hl = model.visibleHighlight(scroll: scroll) else { return }
        let signature = (hl.startRow, hl.startCol, hl.endRow, hl.endCol)
        guard lastAppliedHighlight == nil || lastAppliedHighlight! != signature else { return }
        lastAppliedHighlight = signature
        view.setSelectionRange(
            start: Position(col: hl.startCol, row: hl.startRow),
            end: Position(col: hl.endCol, row: hl.endRow)
        )
    }

    private func inject(_ sequence: String) {
        view?.send(txt: sequence)
    }

    private func paneScroll(_ paneID: String) async throws -> PaneScroll? {
        try await client.snapshot().panes.first { $0.paneID == paneID }?.scroll
    }
}
