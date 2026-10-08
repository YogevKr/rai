import AppKit

@MainActor
enum AppTermination {
    static func schedule(_ terminate: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }) {
        // terminateLater enters a nested AppKit event loop. Calling terminate
        // inside a main-actor task prevents the delegate's cleanup task from
        // running. A run-loop callback lets the calling task return first.
        // DispatchQueue.main.async still holds that queue during the nested loop.
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated { terminate() }
        }
    }
}

/// Bound asynchronous cleanup while preserving AppKit's pending termination
/// request, including requests from system logout and shutdown.
@MainActor
final class AppTerminationCoordinator {
    private enum Phase { case idle, cleaning, ready }
    private var phase = Phase.idle
    private let timeout: Duration
    private var cleanupTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?

    init(timeout: Duration = .seconds(5)) { self.timeout = timeout }

    deinit {
        cleanupTask?.cancel()
        deadlineTask?.cancel()
    }

    func request(
        shutdown: @escaping @MainActor () async -> Void,
        reply: @escaping @MainActor () -> Void
    ) -> NSApplication.TerminateReply {
        if phase == .ready { return .terminateNow }
        guard phase == .idle else { return .terminateLater }
        phase = .cleaning
        cleanupTask = Task { [weak self] in
            await shutdown()
            guard !Task.isCancelled else { return }
            self?.finish(reply: reply)
        }
        deadlineTask = Task { [weak self, timeout] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, phase == .cleaning else { return }
            NSLog("rai: shutdown cleanup timed out; closing the app and preserving Herdr sessions")
            finish(reply: reply)
        }
        return .terminateLater
    }

    private func finish(reply: @escaping @MainActor () -> Void) {
        guard phase == .cleaning else { return }
        phase = .ready
        cleanupTask?.cancel()
        deadlineTask?.cancel()
        cleanupTask = nil
        deadlineTask = nil
        AppTermination.schedule(reply)
    }
}
