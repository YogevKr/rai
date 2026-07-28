import Foundation

/// Built-in firmware LED animations. These are the wire values: the `e` field is
/// an INTEGER, not an effect name. Mirrors `OAILightingEffect` in
/// @worklouder/device-kit-oai — the public reverse-engineering write-ups all
/// describe `e` as a string ("off"/"breath"), which the firmware does not accept.
public enum MicroLightingEffect: Int, Codable, Sendable {
    case off = 0
    case solid = 1
    case snake = 2
    case rainbow = 3
    case breath = 4
    case gradient = 5
    /// Breathing that ranges 0.5...1.0 brightness instead of 0...1.
    case shallowBreath = 6
}

/// One entry of `v.oai.thstatus`. Only `id` is required — every omitted field
/// leaves that aspect unchanged on the device, so encoding must drop nils rather
/// than send defaults.
public struct MicroLightingEntry: Codable, Equatable, Sendable {
    public let id: Int
    /// Packed RGB.
    public let c: Int?
    /// Brightness, 0 (off) ... 1 (full).
    public let b: Double?
    /// Effect, as `MicroLightingEffect.rawValue`.
    public let e: Int?
    /// Effect speed, 0 (stopped) ... 1 (fast).
    public let s: Double?
    /// Keys backlight follows this thread's RGB. Wire form is 1/0, not a bool.
    public let sk: Int?
    /// Ambient ring follows this thread's RGB. Wire form is 1/0, not a bool.
    public let sa: Int?

    public init(
        id: Int,
        c: Int? = nil,
        b: Double? = nil,
        e: Int? = nil,
        s: Double? = nil,
        sk: Int? = nil,
        sa: Int? = nil
    ) {
        self.id = id
        self.c = c
        self.b = b
        self.e = e
        self.s = s
        self.sk = sk
        self.sa = sa
    }
}

public struct MicroLightingStyle: Equatable, Sendable {
    public let color: Int
    public let brightness: Double
    public let effect: MicroLightingEffect
    public let speed: Double
    public let syncKeys: Bool?
    public let syncAmbient: Bool?

    public init(
        color: Int,
        brightness: Double,
        effect: MicroLightingEffect,
        speed: Double,
        syncKeys: Bool? = nil,
        syncAmbient: Bool? = nil
    ) {
        self.color = color
        self.brightness = brightness
        self.effect = effect
        self.speed = speed
        self.syncKeys = syncKeys
        self.syncAmbient = syncAmbient
    }
}

public enum MicroLightingPalette {
    public static let empty = MicroLightingStyle(
        color: 0x000000, brightness: 0, effect: .off, speed: 0
    )
    public static let idle = MicroLightingStyle(
        color: 0xFFFFFF, brightness: 1, effect: .solid, speed: 0
    )
    // Steady, not breathing: a working agent is the normal state on a busy
    // herd, and six pulsing keys read as a fire alarm rather than status.
    public static let working = MicroLightingStyle(
        color: 0x0066FF, brightness: 1, effect: .solid, speed: 0
    )
    public static let blocked = MicroLightingStyle(
        color: 0xFFBF00, brightness: 1, effect: .solid, speed: 0
    )
    public static let done = MicroLightingStyle(
        color: 0x00C853, brightness: 1, effect: .solid, speed: 0
    )

    public static func style(for status: AgentStatus?) -> MicroLightingStyle {
        switch status {
        case nil: empty
        case .idle, .unknown: idle
        case .working: working
        case .blocked: blocked
        case .done: done
        }
    }
}

public struct MicroLighting: Sendable {
    private var lastStyles: [MicroLightingStyle?] = Array(repeating: nil, count: 6)

    public init() {}

    public mutating func changes(
        for slots: [AgentStatus?]
    ) -> [MicroLightingEntry] {
        precondition(slots.count == 6, "Codex Micro has exactly six agent slots")
        var result: [MicroLightingEntry] = []
        for id in slots.indices {
            let style = MicroLightingPalette.style(for: slots[id])
            guard lastStyles[id] != style else { continue }
            lastStyles[id] = style
            result.append(
                MicroLightingEntry(
                    id: id,
                    c: style.color,
                    b: style.brightness,
                    e: style.effect.rawValue,
                    s: style.speed,
                    sk: style.syncKeys.map { $0 ? 1 : 0 },
                    sa: style.syncAmbient.map { $0 ? 1 : 0 }
                )
            )
        }
        return result
    }
}

/// One zone of `v.oai.rgbcfg`. Mirrors `OAILightingSide`; `magic` is an
/// undocumented firmware parameter carried through verbatim.
public struct MicroLightingSide: Codable, Equatable, Sendable {
    public let e: Int
    public let b: Double
    public let s: Double
    public let m: Int
    public let c: Int

    public init(effect: MicroLightingEffect, brightness: Double, speed: Double, magic: Int, color: Int) {
        self.e = effect.rawValue
        self.b = brightness
        self.s = speed
        self.m = magic
        self.c = color
    }
}

/// Params for `v.oai.rgbcfg`: `ambient` drives the outer ring, `keys` the
/// under-keycap lighting.
public struct MicroRGBCfg: Codable, Equatable, Sendable {
    public let ambient: MicroLightingSide
    public let keys: MicroLightingSide

    public init(ambient: MicroLightingSide, keys: MicroLightingSide) {
        self.ambient = ambient
        self.keys = keys
    }
}
