import AppKit
import CorralCore
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

    init(capacity: Int = 8) {
        recency = LRUTracker(capacity: capacity)
    }

    func view(for terminalID: String) -> FocusAwareTerminalView {
        if let entry = entries[terminalID] {
            recency.touch(terminalID)
            return entry.view
        }

        let view = FocusAwareTerminalView(frame: .zero)
        view.font = TerminalPaneView.font
        GhosttyTheme.apply(to: view)
        // Keep SwiftTerm's default mouse reporting unchanged: wheel-driven TUIs
        // scroll, while text selection remains Shift+drag as in Ghostty.

        let coordinator = TerminalProcessCoordinator(terminalID: terminalID)
        view.processDelegate = coordinator
        entries[terminalID] = Entry(view: view, coordinator: coordinator)
        coordinator.attach(view)

        if let evictedID = recency.touch(terminalID) {
            evict(evictedID)
        }
        return view
    }

    func retain(terminalIDs liveTerminalIDs: Set<String>) {
        let staleTerminalIDs = entries.keys.filter {
            !liveTerminalIDs.contains($0)
        }
        for terminalID in staleTerminalIDs {
            evict(terminalID)
        }
    }

    private func evict(_ terminalID: String) {
        guard let entry = entries.removeValue(forKey: terminalID) else { return }
        recency.remove(terminalID)
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
    private var started = false
    private var intentionalStop = false
    private var retries = 0
    private let maxRetries = 5

    init(terminalID: String) {
        self.terminalID = terminalID
    }

    func attach(_ view: LocalProcessTerminalView) {
        guard !started else { return }
        started = true
        self.view = view
        launch()
    }

    func stop(_ view: LocalProcessTerminalView) {
        intentionalStop = true
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

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}
