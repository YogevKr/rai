import AppKit
import Combine
import RaiCore
import SwiftTerm

/// Owns attached terminal views independently of SwiftUI's view lifecycle.
///
/// A terminal can move between lightweight host views while its attach process
/// and scrollback remain alive. Closed terminals are reaped from snapshots, and
/// inactive terminals are bounded by LRU eviction.
@MainActor
final class TerminalPool {
    private struct Entry {
        let view: FocusAwareTerminalView
        let coordinator: TerminalProcessCoordinator
    }

    private var entries: [String: Entry] = [:]
    private var recency: LRUTracker<String>
    private var socketPath: String
    private var themeObserver: AnyCancellable?
    /// Terminals herdr reported in the last snapshot, once one has been seen.
    /// Closing a pane evicts its terminal, but SwiftUI still updates the
    /// outgoing pane's container once on its way out; without this the pool
    /// would re-create the entry and spawn an attach for a terminal that no
    /// longer exists (which then retries its way to nothing).
    private var knownTerminalIDs: Set<String>?

    init(
        capacity: Int = 8,
        socketPath: String = HerdrClient.defaultSocketPath()
    ) {
        recency = LRUTracker(capacity: capacity)
        self.socketPath = socketPath
        // Re-theme + repaint every live terminal the instant the palette changes
        // (RunLoop.main delivery lands after the @Published value has updated).
        themeObserver = SettingsStore.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.reapplyTheme() }
            }
    }

    /// Re-applies the active palette to every pooled terminal and forces a redraw
    /// so already-rendered content recolors immediately, not just new output.
    func reapplyTheme() {
        for entry in entries.values {
            GhosttyTheme.apply(to: entry.view)
            entry.view.needsDisplay = true
        }
    }

    /// The live terminal view for `terminalID`, creating and attaching one on
    /// first use. Returns nil for a terminal herdr has already dropped, so a
    /// closing pane's last SwiftUI update cannot resurrect it.
    func view(for terminalID: String) -> FocusAwareTerminalView? {
        if let entry = entries[terminalID] {
            recency.touch(terminalID)
            // Don't re-theme here: this runs on every SwiftUI render, and each
            // color setter calls updateFullScreen(), forcing constant redraws that
            // fight an active text selection while a program streams output.
            // The palette is applied on creation and re-applied on theme changes.
            return entry.view
        }

        if let knownTerminalIDs, !knownTerminalIDs.contains(terminalID) {
            return nil
        }

        let view = FocusAwareTerminalView(frame: .zero)
        view.font = TerminalPaneView.font
        GhosttyTheme.apply(to: view)
        // Mouse reporting stays off so SwiftTerm never clears a selection while a
        // program streams output (its feed path clears selection whenever this is
        // true). Wheel events are re-enabled per-event by AppDelegate's scroll
        // monitor so mouse-mode TUIs (Claude) still scroll. See
        // FocusAwareTerminalView.handleInterceptedScroll.
        view.allowMouseReporting = false
        // SwiftTerm anchors selections to absolute buffer rows and does not shift
        // them when a full scrollback trims from the top — at the default 500
        // lines a long Claude stream makes a held selection crawl. A deep
        // scrollback keeps trimming (and the drift) out of normal use.
        view.getTerminal().changeScrollback(10_000)
        // Bind the scrollback controller to THIS pool's herd. Its default
        // client points at the default socket, which is wrong the moment the
        // app is attached to another session (remote herd, herd switch).
        view.scrollbackSelection.client = HerdrClient(socketPath: socketPath)

        let coordinator = TerminalProcessCoordinator(
            terminalID: terminalID,
            socketPath: socketPath
        )
        view.processDelegate = coordinator
        entries[terminalID] = Entry(view: view, coordinator: coordinator)
        coordinator.attach(view)

        if let evictedID = recency.touch(terminalID) {
            evict(evictedID)
        }
        return view
    }

    func retain(terminalIDs liveTerminalIDs: Set<String>) {
        knownTerminalIDs = liveTerminalIDs
        let staleTerminalIDs = entries.keys.filter {
            !liveTerminalIDs.contains($0)
        }
        for terminalID in staleTerminalIDs {
            evict(terminalID)
        }
    }

    /// Reaps every attach process before changing herd. New panes inherit the
    /// new API socket when their coordinators are created.
    func switchSocket(to socketPath: String) {
        removeAll()
        self.socketPath = socketPath
    }

    func removeAll() {
        for terminalID in Array(entries.keys) {
            evict(terminalID)
        }
    }

    private func evict(_ terminalID: String) {
        guard let entry = entries.removeValue(forKey: terminalID) else { return }
        recency.remove(terminalID)
        // Stops the pane's scroll-event stream and hides its pill.
        (entry.view as? FocusAwareTerminalView)?.paneID = nil
        entry.view.removeFromSuperview()
        entry.coordinator.stop(entry.view)
    }
}

@MainActor
private final class TerminalProcessCoordinator:
    NSObject,
    @preconcurrency LocalProcessTerminalViewDelegate
{
    private weak var view: LocalProcessTerminalView?
    private let terminalID: String
    private let socketPath: String
    private var started = false
    private var launched = false
    private var pendingLaunch: DispatchWorkItem?
    private var intentionalStop = false
    private var retries = 0
    private let maxRetries = 5

    init(terminalID: String, socketPath: String) {
        self.terminalID = terminalID
        self.socketPath = socketPath
    }

    func attach(_ view: LocalProcessTerminalView) {
        guard !started else { return }
        started = true
        self.view = view
        // Do NOT spawn yet. The pool hands over a view at frame .zero, so the
        // attach would inherit SwiftTerm's default 80x25 pty: herdr renders the
        // pane at 80 columns, the real size lands ~100ms later, and every TUI
        // that reprints on resize leaves an 80-column copy of its output in the
        // scrollback above the reflowed one. Wait for the first real layout.
        //
        // The timer is the floor, not the plan: a pooled view that is never
        // laid out (no window, zero-sized host) must still attach, or its pane
        // would never stream at all.
        let fallback = DispatchWorkItem { [weak self] in
            self?.launchIfNeeded()
        }
        pendingLaunch = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: fallback)
    }

    private func launchIfNeeded() {
        guard !launched, view != nil, !intentionalStop else { return }
        launched = true
        pendingLaunch?.cancel()
        pendingLaunch = nil
        launch()
    }

    func stop(_ view: LocalProcessTerminalView) {
        intentionalStop = true
        pendingLaunch?.cancel()
        pendingLaunch = nil
        view.terminate()
    }

    private func launch() {
        guard let view else { return }
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        let path = env["PATH"] ?? ""
        if !path.contains("/opt/homebrew/bin") {
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:"
                + (path.isEmpty ? "/usr/bin:/bin" : path)
        }
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env["HERDR_SOCKET_PATH"] = socketPath

        view.startProcess(
            executable: HerdrCLI.binaryPath,
            args: ["terminal", "attach", terminalID, "--takeover"],
            environment: env.map { "\($0.key)=\($0.value)" }
        )
    }

    // Unexpected attach exits retry exactly as before. Pool eviction calls
    // stop() first, so intentional termination can never schedule a relaunch.
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard !intentionalStop, retries < maxRetries else { return }
        retries += 1
        let delay = 0.4 * Double(retries)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let view = self.view, !self.intentionalStop else { return }
            view.getTerminal().resetToInitialState()
            self.launch()
        }
    }

    /// The first real layout is the cue to spawn: the pty then starts at the
    /// pane's true size, so herdr renders it once instead of once per width.
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        launchIfNeeded()
    }
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}
