import Foundation
import Network

/// Keep the companion listener responsive while Rai has no foreground window.
/// Releasing the owner ends the activity without preventing idle system sleep.
final class BridgeHostActivity: @unchecked Sendable {
    private let lock = NSLock()
    private let processInfo: ProcessInfo
    private var token: NSObjectProtocol?

    init(listener: NWListener, processInfo: ProcessInfo = .processInfo,
         stateDidChange: @escaping @Sendable (NWListener.State) -> Void) {
        self.processInfo = processInfo
        token = processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Keep companion connections responsive."
        )
        listener.stateUpdateHandler = { [self] state in
            switch state {
            case .failed, .cancelled: stop()
            default: break
            }
            stateDidChange(state)
        }
    }

    func stop() {
        let activity = lock.withLock {
            let activity = token
            token = nil
            return activity
        }
        if let activity { processInfo.endActivity(activity) }
    }

    deinit { stop() }
}
