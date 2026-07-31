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
            viewportRestoreGeneration = UUID()
            viewportRestoreTask?.cancel()
            viewportRestoreTask = nil
            editorTask?.cancel()
            editorTask = nil
            cancelCopyMode()
            stopScrollEventStream()
            lastScroll = nil
            if paneID != nil { startScrollEventStream() }
        }
    }

    /// Pushed on every pane.scroll_changed event (offsetFromBottom == 0 means
    /// the pane follows the live tail). Drives the pane's "back to live" pill.
    var onScrollOffsetChanged: ((PaneScroll) -> Void)?
    var onCopyModeStatusChanged: ((String?) -> Void)?
    var onNotice: ((String) -> Void)?

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
    private var copyModeState: CopyModeState?
    private var copyModeStarting = false
    private var copyModeTask: Task<Void, Never>?
    private var copyModeGeneration = UUID()
    private var copyModeEntryScroll: PaneScroll?
    private var editorTask: Task<Void, Never>?
    private var viewportRestoreTask: Task<Void, Never>?
    private var viewportRestoreGeneration = UUID()

    // MARK: gesture lifecycle

    func mouseDown() {
        if isCopyModeActive {
            exitCopyMode()
        }
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

    // MARK: keyboard copy mode

    var isCopyModeActive: Bool { copyModeStarting || copyModeState != nil }

    func enterCopyMode() {
        guard !isCopyModeActive, let paneID, let view else { return }
        clearSticky()
        view.selectNone()
        model.reset()
        copyModeStarting = true
        copyModeGeneration = UUID()
        let generation = copyModeGeneration
        let pendingRestore = viewportRestoreTask
        onCopyModeStatusChanged?("COPY MODE  Loading…  Esc exits")

        copyModeTask = Task { [weak self, weak view] in
            guard let self, let view else { return }
            do {
                await pendingRestore?.value
                guard !Task.isCancelled, generation == self.copyModeGeneration else {
                    return
                }
                guard let scroll = try await self.paneScroll(paneID) else {
                    throw CopyModeControllerError.missingScrollMetrics
                }
                let read = try await self.client.readPane(
                    paneID: paneID,
                    source: "recent",
                    lines: 1000,
                    format: "ansi",
                    stripANSI: true
                )
                let visible = try await self.client.readPane(
                    paneID: paneID,
                    format: "ansi",
                    stripANSI: true
                )
                guard generation == self.copyModeGeneration else { return }

                let totalRows = max(1, scroll.maxOffsetFromBottom + scroll.viewportRows)
                let readRows = Self.textRowCount(read.text, limit: totalRows)
                self.model.ingest(
                    pageText: read.text,
                    startingAt: max(0, totalRows - readRows),
                    maximumRows: readRows
                )
                self.model.ingest(pageText: visible.text, scroll: scroll)
                let dimensions = view.getTerminal().getDims()
                let terminalCursor = view.getTerminal().getCursorLocation()
                let cursor = ScrollbackSelectionModel.Point(
                    row: ScrollbackSelectionModel.absoluteTop(of: scroll)
                        + min(max(terminalCursor.y, 0), scroll.viewportRows - 1),
                    col: min(max(terminalCursor.x, 0), max(0, dimensions.cols - 1))
                )
                self.copyModeEntryScroll = scroll
                self.lastScroll = scroll
                self.copyModeState = CopyModeState(
                    cursor: cursor,
                    rowBounds: 0...(totalRows - 1),
                    columns: dimensions.cols,
                    viewportRows: scroll.viewportRows
                )
                self.copyModeStarting = false
                self.copyModeTask = nil
                self.updateCopyModePresentation()
            } catch {
                guard generation == self.copyModeGeneration else { return }
                self.cancelCopyMode()
                self.onNotice?("Copy mode could not read this pane")
            }
        }
    }

    /// Returns true whenever copy mode owns the key, including its loading phase.
    func handleCopyModeKey(_ key: CopyModeKey) -> Bool {
        guard isCopyModeActive else { return false }
        if copyModeStarting {
            if key == .escape { cancelCopyMode() }
            return true
        }
        guard var state = copyModeState else { return true }
        if key == .escape {
            copyModeTask?.cancel()
        }
        let beforeCursor = state.cursor
        let effect = state.reduce(key, lines: model.lines)
        copyModeState = state
        syncCopyModeSelection()
        updateCopyModePresentation()

        switch effect {
        case .none:
            if state.cursor != beforeCursor {
                revealCopyModeCursor()
            }
        case .exit:
            exitCopyMode()
        case .yank:
            yankCopyModeSelection()
        case .search(let query, let direction, let repeatSearch):
            runCopyModeSearch(
                query: query,
                direction: direction,
                repeatSearch: repeatSearch
            )
        }
        return true
    }

    func cancelCopyMode() {
        copyModeGeneration = UUID()
        copyModeTask?.cancel()
        copyModeTask = nil
        copyModeStarting = false
        copyModeState = nil
        copyModeEntryScroll = nil
        onCopyModeStatusChanged?(nil)
        if view?.selectionActive == true {
            view?.selectNone()
        }
    }

    private func exitCopyMode() {
        let entryOffset = copyModeEntryScroll?.offsetFromBottom
        let paneID = self.paneID
        let pendingCopyTask = copyModeTask
        cancelCopyMode()
        model.reset()
        guard let entryOffset, let paneID else { return }
        viewportRestoreTask?.cancel()
        viewportRestoreGeneration = UUID()
        let generation = viewportRestoreGeneration
        viewportRestoreTask = Task { [weak self] in
            guard let self else { return }
            await pendingCopyTask?.value
            _ = await self.scrollPane(paneID, toOffset: entryOffset)
            if generation == self.viewportRestoreGeneration {
                self.viewportRestoreTask = nil
            }
        }
    }

    private func yankCopyModeSelection() {
        guard let state = copyModeState, let anchor = state.anchor else {
            exitCopyMode()
            return
        }
        let rows = min(anchor.row, state.cursor.row)...max(anchor.row, state.cursor.row)
        if model.containsAllRows(in: rows) {
            finishCopyModeYank()
            return
        }
        onCopyModeStatusChanged?("COPY MODE  Reading selection…  Esc exits")
        let generation = copyModeGeneration
        copyModeTask?.cancel()
        copyModeTask = Task { [weak self] in
            guard let self else { return }
            let complete = await self.loadFullBuffer()
            guard !Task.isCancelled, generation == self.copyModeGeneration else { return }
            self.syncCopyModeSelection()
            guard complete, self.model.containsAllRows(in: rows) else {
                self.onNotice?("The full selection is not available through this pane")
                self.updateCopyModePresentation()
                return
            }
            self.finishCopyModeYank()
        }
    }

    private func finishCopyModeYank() {
        guard let text = model.assembledText(), !text.isEmpty else {
            exitCopyMode()
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        onNotice?("Copied to clipboard")
        exitCopyMode()
    }

    private func runCopyModeSearch(
        query: String,
        direction: CopyModeSearchDirection,
        repeatSearch: Bool
    ) {
        let generation = copyModeGeneration
        onCopyModeStatusChanged?("COPY MODE  Searching…  Esc exits")
        copyModeTask?.cancel()
        copyModeTask = Task { [weak self] in
            guard let self else { return }
            let complete = await self.loadFullBuffer()
            guard !Task.isCancelled,
                  generation == self.copyModeGeneration,
                  var state = self.copyModeState else {
                return
            }
            let matches = CopyModeState.matches(query: query, in: self.model.lines)
            state.applySearch(
                query: query,
                direction: direction,
                matches: matches,
                isComplete: complete,
                repeatSearch: repeatSearch
            )
            self.copyModeState = state
            self.syncCopyModeSelection()
            self.updateCopyModePresentation()
            self.revealCopyModeCursor()
        }
    }

    private func revealCopyModeCursor() {
        copyModeTask?.cancel()
        let generation = copyModeGeneration
        copyModeTask = Task { [weak self] in
            guard let self, let paneID = self.paneID else { return }
            var stalls = 0
            for _ in 0..<500 {
                guard generation == self.copyModeGeneration,
                      let state = self.copyModeState,
                      let scroll = try? await self.paneScroll(paneID) else {
                    return
                }
                let top = ScrollbackSelectionModel.absoluteTop(of: scroll)
                let bottom = top + scroll.viewportRows - 1
                if state.cursor.row >= top, state.cursor.row <= bottom {
                    if let page = try? await self.client.readPane(
                        paneID: paneID,
                        format: "ansi",
                        stripANSI: true
                    ) {
                        self.model.ingest(pageText: page.text, scroll: scroll)
                    }
                    self.lastScroll = scroll
                    self.syncCopyModeSelection()
                    self.updateCopyModePresentation()
                    return
                }

                let direction: EdgeDirection = state.cursor.row < top ? .up : .down
                let distance = direction == .up
                    ? top - state.cursor.row
                    : state.cursor.row - bottom
                let maxBatch = state.anchor == nil
                    ? 50
                    : max(1, (scroll.viewportRows - 1) / 3)
                let events = min(maxBatch, max(1, (distance + 2) / 3))
                self.inject(String(
                    repeating: direction == .up ? Self.wheelUp : Self.wheelDown,
                    count: events
                ))
                try? await Task.sleep(nanoseconds: 65_000_000)
                guard !Task.isCancelled, generation == self.copyModeGeneration else {
                    return
                }
                guard let after = try? await self.paneScroll(paneID) else { return }
                if after.offsetFromBottom == scroll.offsetFromBottom {
                    stalls += 1
                    if stalls >= 2 {
                        self.onNotice?("This pane owns scrolling; older rows are unavailable")
                        return
                    }
                } else {
                    stalls = 0
                    if let page = try? await self.client.readPane(
                        paneID: paneID,
                        format: "ansi",
                        stripANSI: true
                    ) {
                        self.model.ingest(pageText: page.text, scroll: after)
                    }
                    self.lastScroll = after
                    self.syncCopyModeSelection()
                }
            }
        }
    }

    private func syncCopyModeSelection() {
        guard let state = copyModeState else { return }
        if let anchor = state.anchor {
            model.begin(anchor: anchor)
            model.extendHead(to: state.cursor)
        } else {
            model.resetSelection()
        }
        guard let view, let scroll = lastScroll else { return }
        if let highlight = model.visibleHighlight(scroll: scroll) {
            view.setSelectionRange(
                start: Position(col: highlight.startCol, row: highlight.startRow),
                end: Position(col: highlight.endCol, row: highlight.endRow)
            )
            return
        }
        let visibleRow = state.cursor.row - ScrollbackSelectionModel.absoluteTop(of: scroll)
        if visibleRow >= 0, visibleRow < scroll.viewportRows {
            view.setSelectionRange(
                start: Position(col: state.cursor.col, row: visibleRow),
                end: Position(col: state.cursor.col, row: visibleRow)
            )
        } else if view.selectionActive {
            view.selectNone()
        }
    }

    private func updateCopyModePresentation() {
        guard let state = copyModeState else {
            if !copyModeStarting { onCopyModeStatusChanged?(nil) }
            return
        }
        let location = "\(state.cursor.row + 1):\(state.cursor.col + 1)"
        let status: String
        switch state.mode {
        case .navigation:
            if let result = state.searchResult {
                let current = result.currentIndex.map { String($0 + 1) } ?? "0"
                let suffix = result.isComplete ? "" : "+"
                status = "COPY MODE  \(current)/\(result.matches.count)\(suffix) matches"
                    + "  n/N next  v select  Esc clears"
            } else {
                status = "COPY MODE  \(location)  h/j/k/l move  v select"
                    + "  / search  Esc exits"
            }
        case .visual:
            status = "COPY MODE — VISUAL  \(location)  y/Enter copies"
                + "  Esc cancels  Esc again exits"
        case .search(let prompt):
            let marker = prompt.direction == .forward ? "/" : "?"
            status = "COPY MODE  \(marker)\(prompt.query)▏  Enter searches  Esc cancels"
        }
        onCopyModeStatusChanged?(status)
    }

    // MARK: scrollback editor

    func openScrollbackInEditor() {
        let copyModeRestoreOffset = isCopyModeActive
            ? copyModeEntryScroll?.offsetFromBottom
            : nil
        let pendingCopyTask = copyModeTask
        if isCopyModeActive {
            cancelCopyMode()
            model.reset()
        }
        guard editorTask == nil, let sourcePaneID = paneID else { return }
        let pendingRestore = viewportRestoreTask
        onNotice?("Reading scrollback…")
        editorTask = Task { [weak self] in
            guard let self else { return }
            defer { self.editorTask = nil }
            await pendingCopyTask?.value
            await pendingRestore?.value
            if let copyModeRestoreOffset {
                guard await self.scrollPane(
                    sourcePaneID,
                    toOffset: copyModeRestoreOffset
                ) else {
                    self.onNotice?("The pane viewport could not be restored")
                    return
                }
            }
            let complete = await self.loadFullBuffer()
            guard !Task.isCancelled,
                  self.paneID == sourcePaneID,
                  complete,
                  let state = try? await self.paneScroll(sourcePaneID),
                  let text = self.model.assembledBufferText(
                      rowCount: state.maxOffsetFromBottom + state.viewportRows
                  ) else {
                if !Task.isCancelled, self.paneID == sourcePaneID {
                    self.onNotice?("The full scrollback is not available through this pane")
                }
                return
            }
            do {
                let file = try Self.writeScrollbackFile(text)
                try Self.launchEditor(for: file)
                self.onNotice?("Opened scrollback")
            } catch {
                self.onNotice?("Could not open scrollback: \(error.localizedDescription)")
            }
        }
    }

    /// Loads every retained row. The API caps recent reads at 1,000 rows, so
    /// deeper buffers are paged through the same host-scroll path as selection.
    private func loadFullBuffer() async -> Bool {
        guard let paneID, let initial = try? await paneScroll(paneID) else { return false }
        let totalRows = max(1, initial.maxOffsetFromBottom + initial.viewportRows)
        guard let recent = try? await client.readPane(
            paneID: paneID,
            source: "recent",
            lines: 1000,
            format: "ansi",
            stripANSI: true
        ) else { return false }

        model.reset()
        let recentRows = Self.textRowCount(recent.text, limit: totalRows)
        model.ingest(
            pageText: recent.text,
            startingAt: max(0, totalRows - recentRows),
            maximumRows: recentRows
        )
        if !recent.truncated {
            guard model.assembledBufferText(rowCount: totalRows) != nil else {
                return false
            }
            return await bufferMatches(
                paneID: paneID,
                totalRows: totalRows,
                recent: recent
            )
        }
        guard !Task.isCancelled else { return false }

        guard await scrollPane(paneID, toOffset: 0),
              var scroll = try? await paneScroll(paneID) else {
            return false
        }
        guard !Task.isCancelled else {
            _ = await scrollPane(
                paneID,
                toOffset: initial.offsetFromBottom,
                honorsCancellation: false
            )
            return false
        }
        if let page = try? await client.readPane(
            paneID: paneID,
            format: "ansi",
            stripANSI: true
        ) {
            model.ingest(pageText: page.text, scroll: scroll)
        }

        // Probe once. Mouse-reporting applications consume the wheel without
        // changing host scrollback, and no public API can address older rows.
        inject(Self.wheelUp)
        try? await Task.sleep(nanoseconds: 80_000_000)
        guard !Task.isCancelled else {
            _ = await scrollPane(
                paneID,
                toOffset: initial.offsetFromBottom,
                honorsCancellation: false
            )
            return false
        }
        guard let probe = try? await paneScroll(paneID),
              probe.offsetFromBottom > scroll.offsetFromBottom else {
            _ = await scrollPane(
                paneID,
                toOffset: initial.offsetFromBottom,
                honorsCancellation: false
            )
            return false
        }
        scroll = probe
        if let page = try? await client.readPane(
            paneID: paneID,
            format: "ansi",
            stripANSI: true
        ) {
            model.ingest(pageText: page.text, scroll: scroll)
        }

        var stalls = 0
        for _ in 0..<2000 where scroll.offsetFromBottom < scroll.maxOffsetFromBottom {
            if Task.isCancelled { break }
            let events = max(1, (scroll.viewportRows - 1) / 3)
            inject(String(repeating: Self.wheelUp, count: events))
            try? await Task.sleep(nanoseconds: 65_000_000)
            guard let next = try? await paneScroll(paneID) else { break }
            if next.offsetFromBottom == scroll.offsetFromBottom {
                stalls += 1
                if stalls >= 2 { break }
            } else {
                stalls = 0
                scroll = next
                if let page = try? await client.readPane(
                    paneID: paneID,
                    format: "ansi",
                    stripANSI: true
                ) {
                    model.ingest(pageText: page.text, scroll: scroll)
                }
            }
        }
        let finalRows = scroll.maxOffsetFromBottom + scroll.viewportRows
        let complete = !Task.isCancelled
            && scroll.offsetFromBottom == scroll.maxOffsetFromBottom
            && model.assembledBufferText(rowCount: finalRows) != nil
        _ = await scrollPane(
            paneID,
            toOffset: initial.offsetFromBottom,
            honorsCancellation: false
        )
        lastScroll = try? await paneScroll(paneID)
        guard complete else {
            return false
        }
        return await bufferMatches(
            paneID: paneID,
            totalRows: totalRows,
            recent: recent
        )
    }

    /// A matching tail and geometry prove that paging did not cross an output update.
    private func bufferMatches(
        paneID: String,
        totalRows: Int,
        recent: PaneRead
    ) async -> Bool {
        guard !Task.isCancelled,
              let scroll = try? await paneScroll(paneID),
              scroll.maxOffsetFromBottom + scroll.viewportRows == totalRows,
              let current = try? await client.readPane(
                  paneID: paneID,
                  source: "recent",
                  lines: 1000,
                  format: "ansi",
                  stripANSI: true
              ) else {
            return false
        }
        return current.truncated == recent.truncated && current.text == recent.text
    }

    private func scrollPane(
        _ paneID: String,
        toOffset target: Int,
        honorsCancellation: Bool = true
    ) async -> Bool {
        var bestDistance = Int.max
        for _ in 0..<200 {
            if honorsCancellation, Task.isCancelled { return false }
            guard let scroll = try? await paneScroll(paneID) else { return false }
            let distance = abs(scroll.offsetFromBottom - target)
            if distance == 0 { return true }
            if distance >= bestDistance, bestDistance <= 2 { return true }
            bestDistance = min(bestDistance, distance)
            let up = scroll.offsetFromBottom < target
            let events = min(50, max(1, (distance + 2) / 3))
            inject(String(
                repeating: up ? Self.wheelUp : Self.wheelDown,
                count: events
            ))
            try? await Task.sleep(nanoseconds: 65_000_000)
        }
        return false
    }

    private static func textRowCount(_ text: String, limit: Int) -> Int {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var rows = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        if normalized.hasSuffix("\n"), rows.last?.isEmpty == true {
            rows.removeLast()
        }
        return min(limit, rows.count)
    }

    private static func writeScrollbackFile(_ text: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rai-scrollback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let file = directory.appendingPathComponent("scrollback.txt")
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private static func launchEditor(for file: URL) throws {
        let environment = ProcessInfo.processInfo.environment
        let editor = [environment["VISUAL"], environment["EDITOR"]]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let editor else {
            guard NSWorkspace.shared.open(file) else {
                throw CopyModeControllerError.couldNotOpenEditor
            }
            return
        }

        let commandFile = file.deletingLastPathComponent()
            .appendingPathComponent("open-in-editor.command")
        let command = "\(editor) \(shellQuote(file.path))"
        let script = "#!/bin/zsh\nexec /bin/zsh -lc \(shellQuote(command))\n"
        try script.write(to: commandFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: commandFile.path
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", commandFile.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private enum CopyModeControllerError: Error {
        case missingScrollMetrics
        case couldNotOpenEditor
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
