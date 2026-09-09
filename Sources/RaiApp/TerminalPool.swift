import AppKit
import Combine
import RaiCore
import SwiftTerm

/// Owns attached terminal views independently of SwiftUI's view lifecycle.
///
/// A terminal can move between lightweight host views without losing scrollback.
/// Hidden views suspend their display clients; Herdr keeps their agents running.
/// Closed terminals are reaped from snapshots, and cached views use LRU eviction.
@MainActor
final class TerminalPool {
    private struct Entry {
        let view: FocusAwareTerminalView
        let coordinator: TerminalProcessCoordinator
    }

    private var entries: [String: Entry] = [:]
    private var recency: LRUTracker<String>
    private var socketPath: String
    private let attachExecutable: String?
    var runtimeExecutable: String? {
        didSet {
            guard attachExecutable == nil, let runtimeExecutable else { return }
            for entry in entries.values {
                entry.coordinator.executable = runtimeExecutable
            }
        }
    }
    /// Set alongside `switchSocket`. New local and remote views use different
    /// display thresholds; existing views were already reaped by the switch.
    var predictiveEchoHerdLocation = PredictiveEchoEngine.HerdLocation.local
    private var themeObserver: AnyCancellable?
    private var predictiveEchoSettingObserver: AnyCancellable?
    /// Terminals herdr reported in the last snapshot, once one has been seen.
    /// Closing a pane evicts its terminal, but SwiftUI still updates the
    /// outgoing pane's container once on its way out; without this the pool
    /// would re-create the entry and spawn an attach for a terminal that no
    /// longer exists (which then retries its way to nothing).
    private var knownTerminalIDs: Set<String>?

    /// Floor for the view cache: a small herd still keeps a few panes warm.
    nonisolated static let minimumCapacity = 8
    /// Ceiling, so a very large herd cannot spawn an attach process per pane
    /// without bound. Above this the pool churns again — by then that is the
    /// cheaper failure.
    nonisolated static let maximumCapacity = 32

    init(
        capacity: Int = TerminalPool.minimumCapacity,
        socketPath: String = HerdrClient.defaultSocketPath(),
        attachExecutable: String? = nil
    ) {
        recency = LRUTracker(capacity: capacity)
        self.socketPath = socketPath
        self.attachExecutable = attachExecutable
        // Re-theme + repaint every live terminal the instant the palette changes
        // (RunLoop.main delivery lands after the @Published value has updated).
        themeObserver = SettingsStore.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.reapplyTheme() }
            }
        predictiveEchoSettingObserver = SettingsStore.shared.$predictiveEchoLocalEnabled
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                MainActor.assumeIsolated {
                    self?.applyLocalPredictiveEchoSetting(enabled: enabled)
                }
            }
    }

    /// Test seam: `entries` and the LRU tracker must never drift apart. An entry
    /// the tracker has forgotten can never be evicted, so it holds its attach
    /// process for the app's life and lets the pool exceed its own ceiling.
    var poolStateForTesting: (pooled: Set<String>, tracked: Set<String>, capacity: Int) {
        (Set(entries.keys), Set(recency.leastToMostRecent), recency.capacity)
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
        guard let executable = attachExecutable ?? runtimeExecutable ?? HerdrCLI.resolvedBinaryPath else { return nil }

        let view = FocusAwareTerminalView(frame: .zero)
        view.font = TerminalPaneView.font
        view.notifyUpdateChanges = true
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
        view.configurePredictiveEcho(
            for: Self.enabledPredictiveEchoLocation(
                herdLocation: predictiveEchoHerdLocation,
                localEnabled: SettingsStore.shared.predictiveEchoLocalEnabled
            )
        )

        let coordinator = TerminalProcessCoordinator(
            terminalID: terminalID,
            socketPath: socketPath,
            executable: executable
        )
        view.processDelegate = coordinator
        entries[terminalID] = Entry(view: view, coordinator: coordinator)
        coordinator.attach(view)

        if let evictedID = recency.touch(terminalID) {
            evict(evictedID)
        }
        return view
    }

    nonisolated static func enabledPredictiveEchoLocation(
        herdLocation: PredictiveEchoEngine.HerdLocation,
        localEnabled: Bool
    ) -> PredictiveEchoEngine.HerdLocation? {
        switch herdLocation {
        case .local:
            localEnabled ? .local : nil
        case .remote:
            .remote
        }
    }

    private func applyLocalPredictiveEchoSetting(enabled: Bool) {
        guard predictiveEchoHerdLocation == .local else { return }
        for entry in entries.values {
            entry.view.configurePredictiveEcho(for: enabled ? .local : nil)
        }
    }

    func retain(terminalIDs liveTerminalIDs: Set<String>) {
        knownTerminalIDs = liveTerminalIDs
        // Reap the dead BEFORE re-bounding. A shrinking herd would otherwise
        // spend the smaller capacity on terminals that no longer exist and
        // surrender live keys instead — whose entries stay in `entries` with no
        // LRU tracking, so a later herd above the ceiling grows the pool past
        // its own bound with nothing left to evict.
        let staleTerminalIDs = entries.keys.filter {
            !liveTerminalIDs.contains($0)
        }
        for terminalID in staleTerminalIDs {
            evict(terminalID)
        }
        // Size the pool to the herd. A fixed bound smaller than the pane count
        // makes every visit to a non-resident pane evict an attach and spawn a
        // replacement with `--takeover`, which the displaced herdr client
        // answers by panicking — a herd of 15 panes against the old bound of 8
        // churned attach processes continuously and left a trail of client
        // aborts in DiagnosticReports. The ceiling still caps a runaway herd.
        //
        // Anything the new bound surrenders is evicted for real, so `entries`
        // and the tracker cannot drift apart.
        for evicted in recency.setCapacity(
            min(max(Self.minimumCapacity, liveTerminalIDs.count), Self.maximumCapacity)
        ) {
            evict(evicted)
        }
    }

    /// Reaps every attach process before changing herd. New panes inherit the
    /// new API socket when their coordinators are created.
    func switchSocket(to socketPath: String) {
        removeAll()
        runtimeExecutable = nil
        self.socketPath = socketPath
    }

    func removeAll() {
        for terminalID in Array(entries.keys) {
            evict(terminalID)
        }
    }

    /// External input bypasses the pane's key monitor. Suppress prediction
    /// until the full operation, including a delayed Enter, has finished.
    func beginExternalInput(forPaneIDs paneIDs: Set<String>) {
        guard !paneIDs.isEmpty else { return }
        for entry in entries.values where entry.view.paneID.map(paneIDs.contains) == true {
            entry.view.beginExternalInput()
        }
    }

    func endExternalInput(forPaneIDs paneIDs: Set<String>) {
        guard !paneIDs.isEmpty else { return }
        for entry in entries.values where entry.view.paneID.map(paneIDs.contains) == true {
            entry.view.endExternalInput()
        }
    }

    private func evict(_ terminalID: String) {
        guard let entry = entries.removeValue(forKey: terminalID) else { return }
        recency.remove(terminalID)
        // Stops the pane's scroll-event stream and hides its pill.
        entry.view.paneID = nil
        entry.view.removeFromSuperview()
        entry.coordinator.stop(entry.view)
    }
}

@MainActor
private final class TerminalProcessCoordinator:
    NSObject,
    TerminalProcessViewDelegate
{
    private enum State {
        case suspended, waitingForLayout, attached, waitingToRetry, exhausted, stopped
    }

    private weak var view: FocusAwareTerminalView?
    private let terminalID: String
    private let socketPath: String
    var executable: String
    private var state = State.suspended
    private var hasLaunched = false
    private var pendingLaunch: DispatchWorkItem?
    private var pendingSuspension: DispatchWorkItem?
    private var retries = 0
    private let maxRetries = 5

    init(terminalID: String, socketPath: String, executable: String) {
        self.terminalID = terminalID
        self.socketPath = socketPath
        self.executable = executable
    }

    func attach(_ view: FocusAwareTerminalView) {
        guard self.view == nil, state != .stopped else { return }
        self.view = view
        visibilityChanged(source: view)
    }

    func visibilityChanged(source: TerminalProcessView) {
        guard state != .stopped, let view else { return }
        guard view.isTerminalVisible else {
            cancelPendingLaunch()
            if state == .attached {
                // SwiftUI briefly removes a view while transferring it between
                // hosts. Keep that client's connection during a short transfer.
                guard pendingSuspension == nil else { return }
                let suspension = DispatchWorkItem { [weak self] in
                    guard let self, self.view?.isTerminalVisible == false else { return }
                    self.suspend()
                }
                pendingSuspension = suspension
                DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: suspension)
            } else {
                suspend()
            }
            return
        }

        pendingSuspension?.cancel()
        pendingSuspension = nil
        guard state == .suspended else { return }
        retries = 0
        state = .waitingForLayout
        if hasLaunched {
            // A cached view already has a terminal grid. Reconnect immediately
            // so input after a tab switch cannot fall into the fallback delay.
            launch()
            return
        }
        // Wait for the real grid size before starting the PTY. Only a visible
        // view gets a fallback; cached views must not create display clients.
        let fallback = DispatchWorkItem { [weak self] in
            guard let self, self.state == .waitingForLayout else { return }
            self.launch()
        }
        pendingLaunch = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: fallback)
    }

    private func cancelPendingLaunch() {
        pendingLaunch?.cancel()
        pendingLaunch = nil
    }

    private func suspend() {
        guard state != .stopped else { return }
        cancelPendingLaunch()
        pendingSuspension?.cancel()
        pendingSuspension = nil
        state = .suspended
        // This process is only `herdr terminal attach`. The server owns the
        // agent. Keep the cached terminal buffer intact for the next attach.
        view?.terminate()
    }

    func stop(_ view: FocusAwareTerminalView) {
        state = .stopped
        cancelPendingLaunch()
        pendingSuspension?.cancel()
        pendingSuspension = nil
        view.terminate()
    }

    private func launch() {
        guard state == .waitingForLayout || state == .waitingToRetry,
              let view, view.isTerminalVisible else { return }
        cancelPendingLaunch()
        state = .attached
        hasLaunched = true
        if PredictiveEchoViewPolicy.shouldClear(for: .reattach) {
            view.resetPredictionsForReattach()
        }
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
            executable: executable,
            args: ["terminal", "attach", terminalID, "--takeover"],
            environment: env.map { "\($0.key)=\($0.value)" },
            rawInput: true
        )
    }

    // Retry unexpected exits only while visible. Both suspension and eviction
    // cancel pending retries, so neither can relaunch a hidden display client.
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard state == .attached else { return }
        view?.resetPredictionsForReattach()
        guard view?.isTerminalVisible == true else { suspend(); return }
        guard retries < maxRetries else { state = .exhausted; return }
        retries += 1
        state = .waitingToRetry
        let delay = 0.4 * Double(retries)
        let retry = DispatchWorkItem { [weak self] in
            guard let self, self.state == .waitingToRetry,
                  let view = self.view, view.isTerminalVisible else { return }
            view.getTerminal().resetToInitialState()
            self.launch()
        }
        pendingLaunch = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: retry)
    }

    /// The first real layout is the cue to spawn: the pty then starts at the
    /// pane's true size, so herdr renders it once instead of once per width.
    func sizeChanged(source: TerminalProcessView, newCols: Int, newRows: Int) {
        guard state == .waitingForLayout else { return }
        launch()
    }
    func setTerminalTitle(source: TerminalProcessView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}
