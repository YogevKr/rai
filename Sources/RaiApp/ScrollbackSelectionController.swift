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
    var paneID: String? {
        didSet {
            guard paneID != oldValue else { return }
            stopScrollEventStream()
            lastScroll = nil
            if paneID != nil { startScrollEventStream() }
        }
    }

    /// Pushed on every pane.scroll_changed event (offsetFromBottom == 0 means
    /// the pane follows the live tail). Drives the pane's "back to live" pill.
    var onScrollOffsetChanged: ((PaneScroll) -> Void)?

    private static let wheelUp = "\u{1b}[<64;1;1M"
    private static let wheelDown = "\u{1b}[<65;1;1M"

    /// RPC + event transport for scroll events and scrollback reads. The pool
    /// rebinds this to the ACTIVE herd's socket when it creates the pane view;
    /// the default is only correct for the default herd.
    var client = HerdrClient()
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
    private var scrollEventTask: Task<Void, Never>?
    private var returnToLiveTask: Task<Void, Never>?

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
        } else {
            startScrollEventStream()
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
            self.startScrollEventStream()
        }
    }

    /// Follows herdr's pane.scroll_changed events (delivered the instant the
    /// pane scrolls, payload carries the offsets). Runs for the pane's whole
    /// life: sticky highlights re-anchor at scroll speed, and the pane always
    /// knows whether its viewport left the live tail (the "back to live" pill).
    private func startScrollEventStream() {
        guard scrollEventTask == nil, let paneID else { return }
        let client = self.client
        scrollEventTask = Task { [weak self] in
            while !Task.isCancelled {
                let stream = client.events(
                    subscriptions: ["pane.scroll_changed"], paneIDs: [paneID]
                )
                do {
                    for try await event in stream {
                        guard !Task.isCancelled else { return }
                        guard event.name == "pane.scroll_changed",
                              let scroll = event.scroll else { continue }
                        await MainActor.run { self?.applyScroll(scroll) }
                    }
                } catch {
                    // Fall through to the retry below; the debounced wheel
                    // reconcile covers the gap meanwhile.
                }
                if Task.isCancelled { return }
                // Stream ended (server restart, herd switch): retry quietly.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func stopScrollEventStream() {
        scrollEventTask?.cancel()
        scrollEventTask = nil
    }

    private func applyScroll(_ scroll: PaneScroll) {
        lastScroll = scroll
        onScrollOffsetChanged?(scroll)
        guard model.isActive, let view else { return }
        lastAppliedHighlight = nil
        if let hl = model.visibleHighlight(scroll: scroll) {
            view.setSelectionRange(
                start: Position(col: hl.startCol, row: hl.startRow),
                end: Position(col: hl.endCol, row: hl.endRow)
            )
        } else if view.selectionActive {
            view.selectNone()
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

    // MARK: back to live

    /// herdr scrolls 3 lines per SGR wheel event; one batch covers the current
    /// offset, capped so a deep scrollback unwinds across a few batches.
    static func wheelDownEvents(forOffset offset: Int) -> Int {
        guard offset > 0 else { return 0 }
        return min(50, (offset + 2) / 3)
    }

    /// Unsticks a viewport left scrolled away from the live tail (by an
    /// edge-drag selection or a manual wheel): injects wheel-down through the
    /// attach until the offset reaches zero. Bails on no-progress — the
    /// pane's app owns the wheel, nothing to unstick.
    func returnToLive() {
        guard returnToLiveTask == nil, let paneID else { return }
        returnToLiveTask = Task { [weak self] in
            defer { self?.returnToLiveTask = nil }
            var previous = Int.max
            var stalls = 0
            for _ in 0..<100 {
                guard let self, !Task.isCancelled else { return }
                guard let scroll = (try? await self.paneScroll(paneID)) ?? nil,
                      scroll.offsetFromBottom > 0 else { return }
                let offset = scroll.offsetFromBottom
                if offset >= previous {
                    stalls += 1
                    if stalls >= 3 { return }
                } else {
                    stalls = 0
                }
                previous = offset
                self.inject(String(
                    repeating: Self.wheelDown,
                    count: Self.wheelDownEvents(forOffset: offset)
                ))
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
        }
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
