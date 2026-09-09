import Foundation

public enum EndpointMetadataKind: String, CaseIterable, Sendable {
    case agent, workspace

    public var tokens: [String] {
        switch self {
        case .agent: ["state_icon", "state_text", "machine", "workspace", "tab", "pane", "agent", "terminal_title", "terminal_title_stripped"]
        case .workspace: ["state_icon", "state_text", "workspace", "branch", "git_status"]
        }
    }
}

public struct EndpointMetadataError: LocalizedError, Equatable {
    public let message: String
    public var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

public struct EndpointMetadataStyle: Codable, Equatable, Sendable {
    public var fg: String?
    public var bold: Bool?
    public var dim: Bool?

    public init(fg: String? = nil, bold: Bool? = nil, dim: Bool? = nil) {
        self.fg = fg
        self.bold = bold
        self.dim = dim
    }

    public func validate() throws {
        if let fg, Self.rgb(fg) == nil { throw EndpointMetadataError("Color must use #RGB or #RRGGBB.") }
    }

    public static func rgb(_ value: String) -> UInt32? {
        let bytes = Array(value.utf8)
        guard bytes.first == 35, [4, 7].contains(bytes.count),
              bytes.dropFirst().allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
        let hex = String(value.dropFirst())
        let expanded = bytes.count == 4 ? hex.map { "\($0)\($0)" }.joined() : hex
        return UInt32(expanded, radix: 16)
    }

    public func overriding(_ base: Self) -> Self {
        Self(fg: fg ?? base.fg, bold: bold ?? base.bold, dim: dim ?? base.dim)
    }
}

public struct EndpointMetadataRule: Codable, Equatable, Sendable {
    public enum Condition: String, Codable, CaseIterable, Sendable {
        case equals, contains, startsWith = "starts_with", greaterThan = "gt", lessThan = "lt"
        public var numeric: Bool { self == .greaterThan || self == .lessThan }
        public var label: String {
            switch self {
            case .equals: "Equals"
            case .contains: "Contains"
            case .startsWith: "Starts with"
            case .greaterThan: "Greater than"
            case .lessThan: "Less than"
            }
        }
    }

    public var condition: Condition
    public var value: String
    public var ignoreCase: Bool?
    public var style: EndpointMetadataStyle

    public init(condition: Condition = .equals, value: String = "", ignoreCase: Bool? = nil,
                style: EndpointMetadataStyle = .init()) {
        self.condition = condition
        self.value = value
        self.ignoreCase = ignoreCase
        self.style = style
    }

    public func validate() throws {
        try style.validate()
        if condition.numeric {
            guard Self.number(value) != nil else { throw EndpointMetadataError("Enter a finite number without spaces or units.") }
            guard ignoreCase == nil else { throw EndpointMetadataError("Ignore case applies only to text rules.") }
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.condition == rhs.condition && lhs.ignoreCase == rhs.ignoreCase && lhs.style == rhs.style
            && (lhs.condition.numeric ? number(lhs.value) == number(rhs.value) : lhs.value == rhs.value)
    }

    public func matches(_ text: String) -> Bool {
        if condition.numeric {
            guard let number = Self.number(text), let threshold = Self.number(value) else { return false }
            return condition == .greaterThan ? number > threshold : number < threshold
        }
        let candidate = ignoreCase == true ? Self.fold(text) : Array(text.utf8)
        let expected = ignoreCase == true ? Self.fold(value) : Array(value.utf8)
        switch condition {
        case .equals: return candidate == expected
        case .contains:
            return expected.isEmpty || candidate.indices.contains { offset in
                candidate.count - offset >= expected.count
                    && candidate[offset..<(offset + expected.count)].elementsEqual(expected)
            }
        case .startsWith: return candidate.starts(with: expected)
        default: return false
        }
    }

    private static func fold(_ value: String) -> [UInt8] {
        value.utf8.map { (65...90).contains($0) ? $0 + 32 : $0 }
    }

    private static func number(_ value: String) -> Double? {
        guard value.range(of: #"\A[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\z"#, options: .regularExpression) != nil,
              let number = Double(value), number.isFinite else { return nil }
        return number
    }

    public init(from decoder: Decoder) throws {
        let object = try MetadataObject(decoder, allowed: Condition.allCases.map(\.rawValue) + ["ignore_case", "fg", "bold", "dim"])
        let conditions = Condition.allCases.filter { object.values[$0.rawValue] != nil }
        guard conditions.count == 1, let condition = conditions.first else {
            throw EndpointMetadataError("Each rule needs exactly one condition.")
        }
        self.condition = condition
        if condition.numeric {
            guard let number = object.values[condition.rawValue]?.numberValue, number.isFinite else {
                throw EndpointMetadataError("Numeric conditions need finite numbers.")
            }
            value = String(number)
        } else {
            value = try object.string(condition.rawValue)
        }
        ignoreCase = try object.boolean("ignore_case")
        style = try object.style()
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var object = try MetadataObject.encodedStyle(style)
        if condition.numeric, let number = Self.number(value) { object[condition.rawValue] = .number(number) }
        else { object[condition.rawValue] = .string(value) }
        if let ignoreCase { object["ignore_case"] = .bool(ignoreCase) }
        try object.encode(to: encoder)
    }
}

public struct EndpointMetadataToken: Codable, Equatable, Sendable {
    public var token: String
    public var style: EndpointMetadataStyle
    public var rules: [EndpointMetadataRule]

    public init(_ token: String, style: EndpointMetadataStyle = .init(), rules: [EndpointMetadataRule] = []) {
        self.token = token
        self.style = style
        self.rules = rules
    }

    public func validate(kind: EndpointMetadataKind) throws {
        let custom = token.dropFirst()
        let validCustom = token.hasPrefix("$") && (1...32).contains(custom.utf8.count)
            && custom.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 45 }
        guard kind.tokens.contains(token) || validCustom else { throw EndpointMetadataError("Unknown or invalid token: \(token)") }
        guard rules.count <= 16 else { throw EndpointMetadataError("Each token can have at most 16 rules.") }
        guard rules.isEmpty || !["state_icon", "git_status"].contains(token) else {
            throw EndpointMetadataError("State icons and Git status cannot have rules.")
        }
        try style.validate()
        try rules.forEach { try $0.validate() }
    }

    public func resolvedStyle(for text: String) -> EndpointMetadataStyle {
        rules.first { $0.matches(text) }?.style.overriding(style) ?? style
    }

    public init(from decoder: Decoder) throws {
        if let plain = try? decoder.singleValueContainer().decode(String.self) {
            token = plain
            style = .init()
            rules = []
            return
        }
        let object = try MetadataObject(decoder, allowed: ["token", "fg", "bold", "dim", "rules"])
        token = try object.string("token")
        style = try object.style()
        if let rules = object.values["rules"] {
            self.rules = try JSONDecoder().decode([EndpointMetadataRule].self, from: JSONEncoder().encode(rules))
        } else { self.rules = [] }
    }

    public func encode(to encoder: Encoder) throws {
        if style == .init(), rules.isEmpty {
            var container = encoder.singleValueContainer()
            try container.encode(token)
            return
        }
        var object = try MetadataObject.encodedStyle(style)
        object["token"] = .string(token)
        if !rules.isEmpty { object["rules"] = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(rules)) }
        try object.encode(to: encoder)
    }
}

public struct EndpointMetadataLayout: Codable, Equatable, Sendable {
    public var rows: [[EndpointMetadataToken]]
    public var rowGap: UInt16
    public var rowsByAgent: [String: [[EndpointMetadataToken]]]
    enum CodingKeys: String, CodingKey { case rows, rowGap = "row_gap", rowsByAgent = "rows_by_agent" }

    public init(rows: [[EndpointMetadataToken]], rowGap: UInt16 = 0, rowsByAgent: [String: [[EndpointMetadataToken]]] = [:]) {
        self.rows = rows
        self.rowGap = rowGap
        self.rowsByAgent = rowsByAgent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rows = try container.decode([[EndpointMetadataToken]].self, forKey: .rows)
        rowGap = try container.decodeIfPresent(UInt16.self, forKey: .rowGap) ?? 0
        rowsByAgent = try container.decodeIfPresent([String: [[EndpointMetadataToken]]].self, forKey: .rowsByAgent) ?? [:]
    }

    public func validate(kind: EndpointMetadataKind) throws {
        if kind == .workspace, !rowsByAgent.isEmpty { throw EndpointMetadataError("Agent overrides apply only to agent layouts.") }
        for key in rowsByAgent.keys where !Self.canonicalAgents.contains(key) {
            throw EndpointMetadataError("Unknown canonical agent: \(key)")
        }
        for layout in [rows] + Array(rowsByAgent.values) {
            guard layout.count <= 16, layout.allSatisfy({ $0.count <= 16 }) else {
                throw EndpointMetadataError("Layouts allow at most 16 rows and 16 tokens per row.")
            }
            try layout.flatMap { $0 }.forEach { try $0.validate(kind: kind) }
        }
    }

    public static let canonicalAgents = ["pi", "claude", "codex", "gemini", "cursor", "devin", "agy", "cline", "omp", "mastracode", "opencode", "copilot", "kimi", "kiro", "droid", "amp", "grok", "hermes", "kilo", "qodercli", "qwen", "maki", "muse"]
}

public struct EndpointMetadataConfiguration: Codable, Equatable, Sendable {
    public var agents: EndpointMetadataLayout
    public var spaces: EndpointMetadataLayout

    public init() {
        agents = .init(rows: [["state_icon", "machine", "workspace", "tab"], ["agent"]].map { $0.map { EndpointMetadataToken($0) } })
        spaces = .init(rows: [["state_icon", "workspace"], ["branch", "git_status"]].map { $0.map { EndpointMetadataToken($0) } })
    }

    public subscript(kind: EndpointMetadataKind) -> EndpointMetadataLayout {
        get { kind == .agent ? agents : spaces }
        set { if kind == .agent { agents = newValue } else { spaces = newValue } }
    }

    public func validate() throws {
        try agents.validate(kind: .agent)
        try spaces.validate(kind: .workspace)
    }

    public static func decode(_ text: String) throws -> Self {
        let result = try JSONDecoder().decode(Self.self, from: Data(text.utf8))
        try result.validate()
        return result
    }

    public func encoded() throws -> String {
        try validate()
        return String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }
}

private struct MetadataObject {
    let values: [String: JSONValue]

    init(_ decoder: Decoder, allowed: [String]) throws {
        values = try [String: JSONValue](from: decoder)
        if let unknown = values.keys.first(where: { !allowed.contains($0) }) {
            throw EndpointMetadataError("Unknown metadata field: \(unknown)")
        }
    }

    func string(_ key: String) throws -> String {
        guard let value = values[key]?.stringValue else { throw EndpointMetadataError("\(key) must contain text.") }
        return value
    }

    func boolean(_ key: String) throws -> Bool? {
        guard let value = values[key] else { return nil }
        guard case .bool(let flag) = value else { throw EndpointMetadataError("\(key) must be true or false.") }
        return flag
    }

    func style() throws -> EndpointMetadataStyle {
        let style = EndpointMetadataStyle(fg: try values["fg"].map { _ in try string("fg") },
                                          bold: try boolean("bold"), dim: try boolean("dim"))
        try style.validate()
        return style
    }

    static func encodedStyle(_ style: EndpointMetadataStyle) throws -> [String: JSONValue] {
        try style.validate()
        var result: [String: JSONValue] = [:]
        if let fg = style.fg { result["fg"] = .string(fg) }
        if let bold = style.bold { result["bold"] = .bool(bold) }
        if let dim = style.dim { result["dim"] = .bool(dim) }
        return result
    }
}
