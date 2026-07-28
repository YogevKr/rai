import CoreGraphics
import Foundation
import RaiCore

/// Presence-aware phone pushes: when the user is at the Mac, the Mac's own
/// notification is enough — the phone buzzing in their pocket for a pane two
/// windows away is noise. A push born while the user is active is HELD; a
/// held push polls, dies quietly if the pane gets handled at the desk, and
/// fires only if the pane still wants attention after the user goes idle.
enum HeldPushDecision: Equatable {
    case push
    case cancel
    case wait

    /// `paneStatus` is the pane's CURRENT status (nil when the pane is gone);
    /// `expectedStatus` is the one the push was created for.
    static func evaluate(
        paneStatus: AgentStatus?,
        expectedStatus: AgentStatus,
        isSelectedOnMac: Bool,
        idleSeconds: TimeInterval,
        awayAfter: TimeInterval
    ) -> HeldPushDecision {
        guard let paneStatus, paneStatus == expectedStatus else { return .cancel }
        if isSelectedOnMac { return .cancel }
        return idleSeconds >= awayAfter ? .push : .wait
    }
}

enum UserPresence {
    /// User counts as away after this much input silence.
    static let awayAfter: TimeInterval = 120
    /// Held pushes re-check on this cadence.
    static let pollInterval: TimeInterval = 15

    /// Seconds since the user last touched keyboard or mouse, session-wide.
    /// Minimum across concrete event types — the kCGAnyInputEventType trick
    /// isn't representable in Swift's CGEventType.
    static var idleSeconds: TimeInterval {
        let types: [CGEventType] = [
            .keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown,
            .otherMouseDown, .mouseMoved, .scrollWheel,
        ]
        return types.map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }.min() ?? .infinity
    }
}
