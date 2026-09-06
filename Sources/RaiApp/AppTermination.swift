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
