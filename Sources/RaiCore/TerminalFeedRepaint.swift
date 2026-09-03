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

/// Allows at most one direct repaint for each user input event.
public struct TerminalFeedRepaintState {
    public static let recentInputWindowNanoseconds: UInt64 = 150_000_000

    private var inputGeneration: UInt64 = 0
    private var repaintedGeneration: UInt64 = 0
    private var lastInputUptimeNanoseconds: UInt64 = 0

    public init() {}

    public mutating func noteUserInput(
        at uptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        inputGeneration &+= 1
        lastInputUptimeNanoseconds = uptimeNanoseconds
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
        let hasRecentInput = lastInputUptimeNanoseconds > 0
            && uptimeNanoseconds >= lastInputUptimeNanoseconds
            && uptimeNanoseconds - lastInputUptimeNanoseconds
                <= Self.recentInputWindowNanoseconds
        let repainted = TerminalFeedRepaintPolicy.repaintIfNeeded(
            byteCount: byteCount,
            isFocused: isFocused,
            isVisible: isVisible,
            hasRecentUnpaintedUserInput: hasRecentInput
                && inputGeneration != repaintedGeneration,
            synchronizedOutputActive: synchronizedOutputActive,
            repaint: repaint
        )
        if repainted {
            repaintedGeneration = inputGeneration
        }
        return repainted
    }
}
