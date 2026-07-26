import Foundation

public enum MicroPressState: Int, Codable, Equatable, Sendable {
    case release = 0
    case press = 1
}

public enum MicroEncoderAction: Equatable, Sendable {
    case clockwise
    case counterclockwise
    case press
    case release
}

public enum MicroJoystickDirection: String, CaseIterable, Equatable, Sendable {
    case right
    case down
    case left
    case up
}

public enum MicroKeySemantic: Equatable, Sendable {
    case agent(Int)
    case command(String)
    case encoder(MicroEncoderAction)
}

public enum MicroKeyMap {
    /// Verified live: pressing the six agent keys left to right produced
    /// AG00..AG05 in order, each with a matching release (act:0).
    public static let agentIDs = (0..<6).map { String(format: "AG%02d", $0) }

    /// ACT06...ACT12 — **seven** ids, contiguous. Public write-ups list six and
    /// skip ACT11; the hardware emits it (captured live), so omitting it dropped
    /// real presses on the floor.
    public static let commandIDs = [
        "ACT06", "ACT07", "ACT08", "ACT09", "ACT10", "ACT11", "ACT12",
    ]

    public static func semantic(for keyID: String, action: Int) -> MicroKeySemantic? {
        if let index = agentIDs.firstIndex(of: keyID), action == 0 || action == 1 {
            return .agent(index)
        }
        if commandIDs.contains(keyID), action == 0 || action == 1 {
            return .command(keyID)
        }
        switch (keyID, action) {
        case ("ENC_CW", 2): return .encoder(.clockwise)
        case ("ENC_CC", 2): return .encoder(.counterclockwise)
        // The dial press reports as ENC_CLK on real firmware, not ENC.
        // ENC is kept as a documented-but-unobserved alias.
        case ("ENC_CLK", 1), ("ENC", 1): return .encoder(.press)
        case ("ENC_CLK", 0), ("ENC", 0): return .encoder(.release)
        default: return nil
        }
    }

    /// Converts the analog stick's continuous polar stream into directional
    /// press/release edges.
    ///
    /// The stick reports `{angle, distance}` samples while off-centre; distance
    /// is continuous and does not reach 1.0 in practice (0.92 was the maximum
    /// observed on real hardware). Edges therefore need thresholds with
    /// hysteresis, and the direction must be **latched** at press time so the
    /// release reports the direction that was actually held rather than
    /// whatever the stick was passing through as it recentred.
    public struct MicroJoystickTracker: Sendable {
        public let pressThreshold: Double
        public let releaseThreshold: Double
        private var latched: MicroJoystickDirection?

        public init(pressThreshold: Double = 0.6, releaseThreshold: Double = 0.35) {
            precondition(releaseThreshold < pressThreshold, "hysteresis requires release < press")
            self.pressThreshold = pressThreshold
            self.releaseThreshold = releaseThreshold
        }

        public var heldDirection: MicroJoystickDirection? { latched }

        /// Returns the edges this sample produced, in order. Rolling from one
        /// direction to another while held yields a release then a press.
        public mutating func update(
            angle: Double,
            distance: Double
        ) -> [(direction: MicroJoystickDirection, state: MicroPressState)] {
            guard angle.isFinite, distance.isFinite else { return [] }
            let direction = MicroKeyMap.joystickDirection(angle: angle)

            if let held = latched {
                if distance <= releaseThreshold {
                    latched = nil
                    return [(held, .release)]
                }
                if let direction, direction != held, distance >= pressThreshold {
                    latched = direction
                    return [(held, .release), (direction, .press)]
                }
                return []
            }

            guard distance >= pressThreshold, let direction else { return [] }
            latched = direction
            return [(direction, .press)]
        }
    }

    public static func joystickDirection(
        angle: Double,
        tolerance: Double = 0.08
    ) -> MicroJoystickDirection? {
        guard angle.isFinite, tolerance >= 0 else { return nil }
        let normalized = angle - floor(angle)
        let candidates: [(MicroJoystickDirection, Double)] = [
            (.right, 0), (.down, 0.25), (.left, 0.5), (.up, 0.75),
        ]
        return candidates.first { _, target in
            let delta = abs(normalized - target)
            return min(delta, 1 - delta) <= tolerance
        }?.0
    }
}
