import Foundation

/// Selects terminal feeds that can bypass SwiftTerm's frame-rate throttle.
/// A shell echo is small. Agent output can be large and must stay coalesced.
public enum TerminalFeedRepaintPolicy {
    /// Keep 512-byte and larger chunks on the throttled output path.
    public static let immediateByteLimit = 512

    @discardableResult
    public static func repaintIfNeeded(
        byteCount: Int,
        isFocused: Bool,
        isVisible: Bool,
        hasRecentUnpaintedUserInput: Bool,
        synchronizedOutputActive: Bool,
        repaint: () -> Void
    ) -> Bool {
        guard byteCount < immediateByteLimit,
              isFocused,
              isVisible,
              hasRecentUnpaintedUserInput,
              !synchronizedOutputActive
        else {
            return false
        }
        repaint()
        return true
    }
}

/// Decides how a feed enters SwiftTerm before SwiftTerm can select its own path.
public struct TerminalFeedRepaintState {
    public enum Disposition: Equatable {
        case feedNowAndRepaint
        case deferToFrame(deadlineUptimeNanoseconds: UInt64)
        case feedNormally
    }

    public static let recentInputWindowNanoseconds: UInt64 = 150_000_000
    public static let frameIntervalNanoseconds: UInt64 = 16_700_000

    private var lastInputUptimeNanoseconds: UInt64 = 0
    private var lastImmediateRepaintUptimeNanoseconds: UInt64?

    public init() {}

    public mutating func noteUserInput(
        at uptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        lastInputUptimeNanoseconds = uptimeNanoseconds
    }

    public mutating func disposition(
        byteCount: Int,
        isFocused: Bool,
        isVisible: Bool,
        synchronizedOutputActive: Bool,
        at uptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Disposition {
        guard hasRecentInput(at: uptimeNanoseconds),
              isFocused,
              isVisible,
              !synchronizedOutputActive else {
            return .feedNormally
        }

        if byteCount >= TerminalFeedRepaintPolicy.immediateByteLimit {
            return .deferToFrame(
                deadlineUptimeNanoseconds: nextFrameDeadline(from: uptimeNanoseconds)
            )
        }

        if let lastImmediateRepaintUptimeNanoseconds {
            let deadline = lastImmediateRepaintUptimeNanoseconds
                &+ Self.frameIntervalNanoseconds
            if uptimeNanoseconds < deadline {
                return .deferToFrame(deadlineUptimeNanoseconds: deadline)
            }
        }

        lastImmediateRepaintUptimeNanoseconds = uptimeNanoseconds
        return .feedNowAndRepaint
    }

    public mutating func noteDeferredFramePaint(
        at uptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        lastImmediateRepaintUptimeNanoseconds = uptimeNanoseconds
    }

    @discardableResult
    public mutating func repaintIfNeeded(
        byteCount: Int,
        isFocused: Bool,
        isVisible: Bool,
        synchronizedOutputActive: Bool,
        at uptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds,
        repaint: () -> Void
    ) -> Bool {
        guard disposition(
            byteCount: byteCount,
            isFocused: isFocused,
            isVisible: isVisible,
            synchronizedOutputActive: synchronizedOutputActive,
            at: uptimeNanoseconds
        ) == .feedNowAndRepaint else {
            return false
        }
        repaint()
        return true
    }

    private func hasRecentInput(at uptimeNanoseconds: UInt64) -> Bool {
        lastInputUptimeNanoseconds > 0
            && uptimeNanoseconds >= lastInputUptimeNanoseconds
            && uptimeNanoseconds - lastInputUptimeNanoseconds
                <= Self.recentInputWindowNanoseconds
    }

    private func nextFrameDeadline(from uptimeNanoseconds: UInt64) -> UInt64 {
        guard let lastImmediateRepaintUptimeNanoseconds else {
            return uptimeNanoseconds &+ Self.frameIntervalNanoseconds
        }
        return max(
            uptimeNanoseconds,
            lastImmediateRepaintUptimeNanoseconds &+ Self.frameIntervalNanoseconds
        )
    }
}
