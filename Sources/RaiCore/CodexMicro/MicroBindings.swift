import Combine
import Foundation

public enum MicroControl: Hashable, CaseIterable, Sendable {
    case agentKey(Int)
    case commandKey(String)
    case dialClockwise
    case dialCounterClockwise
    case dialPress
    case joystick(MicroJoystickDirection)

    public static let allCases: [MicroControl] =
        (0..<6).map(MicroControl.agentKey)
        + MicroKeyMap.commandIDs.map(MicroControl.commandKey)
        + [.dialClockwise, .dialCounterClockwise, .dialPress]
        + MicroJoystickDirection.allCases.map(MicroControl.joystick)

    public var id: String {
        switch self {
        case .agentKey(let index): "agent.\(index)"
        case .commandKey(let id): "command.\(id)"
        case .dialClockwise: "dial.clockwise"
        case .dialCounterClockwise: "dial.counterclockwise"
        case .dialPress: "dial.press"
        case .joystick(let direction): "joystick.\(direction.rawValue)"
        }
    }

    public var displayName: String {
        switch self {
        case .agentKey(let index): "Agent \(index + 1)"
        case .commandKey(let id): id
        case .dialClockwise: "Turn clockwise"
        case .dialCounterClockwise: "Turn counterclockwise"
        case .dialPress: "Press dial"
        case .joystick(let direction): direction.rawValue.capitalized
        }
    }

    public var group: String {
        switch self {
        case .agentKey: "Agent keys"
        case .commandKey: "Command keys"
        case .dialClockwise, .dialCounterClockwise, .dialPress: "Dial"
        case .joystick: "Joystick"
        }
    }
}

extension MicroControl: Codable {
    public init(from decoder: Decoder) throws {
        let id = try decoder.singleValueContainer().decode(String.self)
        guard let control = Self.allCases.first(where: { $0.id == id }) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Unknown Codex Micro control \(id)"
            )
        }
        self = control
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(id)
    }
}

public enum MicroAction: Codable, Equatable, Hashable, Sendable {
    case sendReturn
    case interruptEscape
    case stopCtrlC
    case approve
    case deny
    case customKeys(String)
    case customText(String)
    case nextAgent
    case prevAgent
    case focusPane(String)
    case selectSlot(Int)
    case toggleOnlyNeedsYou
    case newTab
    case closeTab
    case reopenClosedTab
    case newWorkspace
    case collapseSpace
    case splitRight
    case splitDown
    case closePane
    case commandPalette
    case broadcast
    case wisprFlow
    case none

    public var displayName: String {
        switch self {
        case .sendReturn: "Send Return"
        case .interruptEscape: "Interrupt (Escape)"
        case .stopCtrlC: "Stop (Ctrl-C)"
        case .approve: "Approve"
        case .deny: "Deny"
        case .customKeys: "Custom keystroke"
        case .customText: "Custom text"
        case .nextAgent: "Next agent"
        case .prevAgent: "Previous agent"
        case .focusPane(let direction):
            "Focus \(Self.directionName(direction))"
        case .selectSlot(let index): "Select agent \(index + 1)"
        case .toggleOnlyNeedsYou: "Toggle only needs-you"
        case .newTab: "New tab"
        case .closeTab: "Close tab"
        case .reopenClosedTab: "Reopen closed tab"
        case .newWorkspace: "New space"
        case .collapseSpace: "Collapse/expand space"
        case .splitRight: "Split right"
        case .splitDown: "Split down"
        case .closePane: "Close pane"
        case .commandPalette: "Command palette"
        case .broadcast: "Broadcast"
        case .wisprFlow: "Wispr Flow"
        case .none: "None"
        }
    }

    public var group: String {
        switch self {
        case .sendReturn, .interruptEscape, .stopCtrlC, .approve, .deny,
             .customKeys, .customText:
            "To focused agent"
        case .nextAgent, .prevAgent, .focusPane, .selectSlot, .toggleOnlyNeedsYou:
            "Navigate"
        case .newTab, .closeTab, .reopenClosedTab, .newWorkspace, .collapseSpace,
             .splitRight, .splitDown, .closePane:
            "Tabs/spaces"
        case .commandPalette, .broadcast, .wisprFlow, .none:
            "App"
        }
    }

    /// Concrete variants presented by Settings. Parameterized actions are
    /// represented by every useful direction/slot plus an initially empty
    /// custom payload; the editor preserves the current payload while its row
    /// remains selected.
    public static let catalog: [MicroAction] = [
        .sendReturn, .interruptEscape, .stopCtrlC, .approve, .deny,
        .customKeys(""), .customText(""),
        .nextAgent, .prevAgent,
        .focusPane("r"), .focusPane("d"), .focusPane("l"), .focusPane("u"),
        .selectSlot(0), .selectSlot(1), .selectSlot(2),
        .selectSlot(3), .selectSlot(4), .selectSlot(5),
        .toggleOnlyNeedsYou,
        .newTab, .closeTab, .reopenClosedTab, .newWorkspace, .collapseSpace,
        .splitRight, .splitDown, .closePane,
        .commandPalette, .broadcast, .wisprFlow, .none,
    ]

    public var catalogID: String {
        switch self {
        case .customKeys: return "customKeys"
        case .customText: return "customText"
        default:
            // Encoding is stable and avoids maintaining a second exhaustive id map.
            let data = try? JSONEncoder().encode(self)
            return data.flatMap { String(data: $0, encoding: .utf8) } ?? displayName
        }
    }

    private static func directionName(_ direction: String) -> String {
        switch direction {
        case "r": "right"
        case "d": "down"
        case "l": "left"
        case "u": "up"
        default: direction
        }
    }
}

/// Persisted, observable binding table shared by Settings and the controller.
/// Keys are encoded with `MicroControl.id`, so adding enum cases later cannot
/// silently reorder or invalidate an existing user's JSON.
public final class MicroBindings: ObservableObject, Codable {
    public static let defaultsKey = "codexMicroBindings"

    @Published public private(set) var table: [MicroControl: MicroAction]

    public init(table: [MicroControl: MicroAction] = [:]) {
        self.table = table
    }

    public static var `default`: MicroBindings {
        var table = Dictionary(
            uniqueKeysWithValues: MicroControl.allCases.map { ($0, MicroAction.none) }
        )
        for index in 0..<6 {
            table[.agentKey(index)] = .selectSlot(index)
        }
        for direction in MicroJoystickDirection.allCases {
            table[.joystick(direction)] = .focusPane(
                String(direction.rawValue.prefix(1))
            )
        }
        table[.dialClockwise] = .prevAgent
        table[.dialCounterClockwise] = .nextAgent
        table[.dialPress] = .commandPalette
        table[.commandKey("ACT10")] = .wisprFlow
        table[.commandKey("ACT11")] = .sendReturn
        return MicroBindings(table: table)
    }

    public subscript(control: MicroControl) -> MicroAction {
        get { table[control] ?? .none }
        set { table[control] = newValue }
    }

    public func reset() {
        table = Self.default.table
    }

    public func copy() -> MicroBindings {
        MicroBindings(table: table)
    }

    private enum CodingKeys: String, CodingKey {
        case bindings
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encoded = try container.decode([String: MicroAction].self, forKey: .bindings)
        table = Dictionary(uniqueKeysWithValues: encoded.compactMap { id, action in
            MicroControl.allCases.first(where: { $0.id == id }).map { ($0, action) }
        })
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            Dictionary(uniqueKeysWithValues: table.map { ($0.key.id, $0.value) }),
            forKey: .bindings
        )
    }

    public static func load(from defaults: UserDefaults = .standard) -> MicroBindings {
        guard let data = defaults.data(forKey: defaultsKey),
              let bindings = try? JSONDecoder().decode(MicroBindings.self, from: data) else {
            return .default
        }
        // New controls receive their defaults while every decoded user choice
        // remains authoritative.
        let merged = Self.default.table.merging(bindings.table) { _, saved in saved }
        return MicroBindings(table: merged)
    }

    public func persist(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
