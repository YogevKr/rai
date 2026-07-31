import Foundation

/// A client-defined agents-panel view. This matches herdr's
/// `AgentViewSetParams` wire shape.
public struct AgentViewSetParams: Codable, Equatable, Sendable {
    public let source: String
    public let label: String?
    public let filter: AgentViewFilter?
    public let sort: [AgentViewSort]

    public init(
        source: String,
        label: String? = nil,
        filter: AgentViewFilter? = nil,
        sort: [AgentViewSort] = []
    ) {
        self.source = source
        self.label = label
        self.filter = filter
        self.sort = sort
    }

    public var displayLabel: String { label ?? "filtered" }

    enum CodingKeys: String, CodingKey {
        case source, label, filter, sort
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(String.self, forKey: .source)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        filter = try container.decodeIfPresent(AgentViewFilter.self, forKey: .filter)
        sort = container.contains(.sort)
            ? try container.decode([AgentViewSort].self, forKey: .sort)
            : []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encodeIfPresent(filter, forKey: .filter)
        if !sort.isEmpty {
            try container.encode(sort, forKey: .sort)
        }
    }
}

public indirect enum AgentViewFilter: Equatable, Sendable {
    case all([AgentViewFilter])
    case any([AgentViewFilter])
    case not(AgentViewFilter)
    case equal(field: AgentViewField, value: AgentViewValue)
    case oneOf(field: AgentViewField, values: [AgentViewValue])
    case exists(AgentViewField)
}

extension AgentViewFilter: Codable {
    private enum CodingKeys: String, CodingKey {
        case op, filters, filter, field, value, values
    }

    private enum Operation: String, Codable {
        case all, any, not, equal = "eq", oneOf = "in", exists
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Operation.self, forKey: .op) {
        case .all:
            self = .all(try container.decode([AgentViewFilter].self, forKey: .filters))
        case .any:
            self = .any(try container.decode([AgentViewFilter].self, forKey: .filters))
        case .not:
            self = .not(try container.decode(AgentViewFilter.self, forKey: .filter))
        case .equal:
            self = .equal(
                field: try container.decode(AgentViewField.self, forKey: .field),
                value: try container.decode(AgentViewValue.self, forKey: .value)
            )
        case .oneOf:
            self = .oneOf(
                field: try container.decode(AgentViewField.self, forKey: .field),
                values: try container.decode([AgentViewValue].self, forKey: .values)
            )
        case .exists:
            self = .exists(try container.decode(AgentViewField.self, forKey: .field))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .all(filters):
            try container.encode(Operation.all, forKey: .op)
            try container.encode(filters, forKey: .filters)
        case let .any(filters):
            try container.encode(Operation.any, forKey: .op)
            try container.encode(filters, forKey: .filters)
        case let .not(filter):
            try container.encode(Operation.not, forKey: .op)
            try container.encode(filter, forKey: .filter)
        case let .equal(field, value):
            try container.encode(Operation.equal, forKey: .op)
            try container.encode(field, forKey: .field)
            try container.encode(value, forKey: .value)
        case let .oneOf(field, values):
            try container.encode(Operation.oneOf, forKey: .op)
            try container.encode(field, forKey: .field)
            try container.encode(values, forKey: .values)
        case let .exists(field):
            try container.encode(Operation.exists, forKey: .op)
            try container.encode(field, forKey: .field)
        }
    }
}

public enum AgentViewField: Equatable, Sendable {
    case builtin(AgentViewBuiltinField)
    case token(String)
}

extension AgentViewField: Codable {
    private struct Token: Codable {
        let token: String
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let builtin = try? container.decode(AgentViewBuiltinField.self) {
            self = .builtin(builtin)
        } else {
            self = .token(try container.decode(Token.self).token)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .builtin(field):
            try container.encode(field)
        case let .token(token):
            try container.encode(Token(token: token))
        }
    }
}

public enum AgentViewBuiltinField: String, Codable, Equatable, Sendable {
    case status
    case workspaceID = "workspace_id"
    case tabID = "tab_id"
    case paneID = "pane_id"
    case agent
    case seen
    case stateChangeSequence = "state_change_seq"
}

public enum AgentViewValue: Equatable, Sendable {
    case string(String)
    case bool(Bool)
    case number(UInt64)
    case context(AgentViewContext)
}

extension AgentViewValue: Codable {
    private struct ContextValue: Codable {
        let context: AgentViewContext
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let context = try? container.decode(ContextValue.self) {
            self = .context(context.context)
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(UInt64.self) {
            self = .number(number)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .context(context):
            try container.encode(ContextValue(context: context))
        }
    }
}

public enum AgentViewContext: String, Codable, Equatable, Sendable {
    case currentWorkspaceID = "current_workspace_id"
    case currentTabID = "current_tab_id"
}

public struct AgentViewSort: Codable, Equatable, Sendable {
    public let field: AgentViewSortField
    public let order: AgentViewSortOrder

    public init(field: AgentViewSortField, order: AgentViewSortOrder = .ascending) {
        self.field = field
        self.order = order
    }

    enum CodingKeys: String, CodingKey {
        case field, order
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        field = try container.decode(AgentViewSortField.self, forKey: .field)
        order = container.contains(.order)
            ? try container.decode(AgentViewSortOrder.self, forKey: .order)
            : .ascending
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(field, forKey: .field)
        if order != .ascending {
            try container.encode(order, forKey: .order)
        }
    }
}

public enum AgentViewSortField: Equatable, Sendable {
    case builtin(AgentViewBuiltinSortField)
    case token(String)
}

extension AgentViewSortField: Codable {
    private struct Token: Codable {
        let token: String
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let builtin = try? container.decode(AgentViewBuiltinSortField.self) {
            self = .builtin(builtin)
        } else {
            self = .token(try container.decode(Token.self).token)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .builtin(field):
            try container.encode(field)
        case let .token(token):
            try container.encode(Token(token: token))
        }
    }
}

public enum AgentViewBuiltinSortField: String, Codable, Equatable, Sendable {
    case workspaceOrder = "workspace_order"
    case tabOrder = "tab_order"
    case paneOrder = "pane_order"
    case attention
    case status
    case agent
    case seen
    case stateChangeSequence = "state_change_seq"
}

public enum AgentViewSortOrder: String, Codable, Equatable, Sendable {
    case ascending = "asc"
    case descending = "desc"
}

/// The fields herdr's agent-view evaluator reads from one agents-panel row.
public struct AgentViewRecord: Equatable, Sendable {
    public let status: AgentStatus
    public let workspaceID: String?
    public let tabID: String?
    public let paneID: String?
    public let agent: String?
    public let seen: Bool
    public let stateChangeSequence: UInt64?
    public let tokens: [String: String]
    public let workspaceOrder: UInt64?
    public let tabOrder: UInt64?
    public let paneOrder: UInt64?

    public init(
        status: AgentStatus,
        workspaceID: String? = nil,
        tabID: String? = nil,
        paneID: String? = nil,
        agent: String? = nil,
        seen: Bool = true,
        stateChangeSequence: UInt64? = nil,
        tokens: [String: String] = [:],
        workspaceOrder: UInt64? = nil,
        tabOrder: UInt64? = nil,
        paneOrder: UInt64? = nil
    ) {
        self.status = status
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.paneID = paneID
        self.agent = agent
        self.seen = seen
        self.stateChangeSequence = stateChangeSequence
        self.tokens = tokens
        self.workspaceOrder = workspaceOrder
        self.tabOrder = tabOrder
        self.paneOrder = paneOrder
    }
}

public struct AgentViewEvaluationContext: Equatable, Sendable {
    public let currentWorkspaceID: String?
    public let currentTabID: String?

    public init(currentWorkspaceID: String? = nil, currentTabID: String? = nil) {
        self.currentWorkspaceID = currentWorkspaceID
        self.currentTabID = currentTabID
    }
}

public struct AgentViewValidationError: Error, Equatable, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// Pure validation and evaluation of herdr-compatible agent views.
public enum AgentViewEvaluator {
    public static let maximumFilterDepth = 8
    public static let maximumFilterNodes = 64
    public static let maximumFilterValues = 32
    public static let maximumSortFields = 8
    public static let maximumSourceCharacters = 120
    public static let maximumLabelCharacters = 32

    /// Validates the view and returns herdr's normalized source and label.
    public static func validate(_ spec: AgentViewSetParams) throws -> AgentViewSetParams {
        let source = try normalizeSource(spec.source)
        let label = try spec.label.map(normalizeLabel)
        var nodes = 0
        if let filter = spec.filter {
            try validate(filter, depth: 1, nodes: &nodes)
        }
        guard spec.sort.count <= maximumSortFields else {
            throw validationError(
                "agent view sort may contain at most \(maximumSortFields) fields"
            )
        }
        for sort in spec.sort {
            try validate(sort.field)
        }
        return AgentViewSetParams(
            source: source,
            label: label,
            filter: spec.filter,
            sort: spec.sort
        )
    }

    /// Filters and sorts records. An empty custom sort uses the selected
    /// built-in order, as herdr does.
    public static func apply(
        _ spec: AgentViewSetParams,
        to records: [AgentViewRecord],
        context: AgentViewEvaluationContext = AgentViewEvaluationContext(),
        fallbackSort: AgentPanelSort = .grouped
    ) throws -> [AgentViewRecord] {
        let spec = try validate(spec)
        let filtered: [AgentViewRecord]
        if let filter = spec.filter {
            filtered = records.filter {
                matches($0, filter: filter, context: context)
            }
        } else {
            filtered = records
        }

        if !spec.sort.isEmpty {
            return stableSort(filtered) { left, right in
                compare(left, right, sorts: spec.sort)
            }
        }
        guard fallbackSort == .priority else { return filtered }
        return stableSort(filtered) { left, right in
            let attention = compareNumbers(
                UInt64(AgentPanel.attentionPriority(left.status)),
                UInt64(AgentPanel.attentionPriority(right.status))
            )
            if attention != 0 { return -attention }
            return compareOptionalNumbersDescending(
                left.stateChangeSequence,
                right.stateChangeSequence
            )
        }
    }

    private static func normalizeSource(_ source: String) throws -> String {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let validCharacters = source.unicodeScalars.allSatisfy {
            ($0.isASCII && CharacterSet.alphanumerics.contains($0))
                || ":._-".unicodeScalars.contains($0)
        }
        guard !source.isEmpty,
              source.unicodeScalars.count <= maximumSourceCharacters,
              validCharacters else {
            throw validationError(
                "agent view source must be non-empty, at most "
                    + "\(maximumSourceCharacters) characters, and contain only ASCII letters, "
                    + "digits, colon, dot, underscore, or hyphen"
            )
        }
        return source
    }

    private static func normalizeLabel(_ label: String) throws -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = trimmed.unicodeScalars
            .filter { $0.properties.generalCategory != .control }
            .map(String.init)
            .joined()
        guard !label.isEmpty,
              label.unicodeScalars.count <= maximumLabelCharacters else {
            throw validationError(
                "agent view label must be non-empty and at most "
                    + "\(maximumLabelCharacters) characters"
            )
        }
        return label
    }

    private static func validate(
        _ filter: AgentViewFilter,
        depth: Int,
        nodes: inout Int
    ) throws {
        guard depth <= maximumFilterDepth else {
            throw validationError(
                "agent view filter may be nested at most \(maximumFilterDepth) levels"
            )
        }
        nodes += 1
        guard nodes <= maximumFilterNodes else {
            throw validationError(
                "agent view filter may contain at most \(maximumFilterNodes) nodes"
            )
        }

        switch filter {
        case let .all(filters), let .any(filters):
            guard !filters.isEmpty else {
                throw validationError("agent view all/any filters must not be empty")
            }
            for filter in filters {
                try validate(filter, depth: depth + 1, nodes: &nodes)
            }
        case let .not(filter):
            try validate(filter, depth: depth + 1, nodes: &nodes)
        case let .equal(field, value):
            try validate(field, value: value)
        case let .oneOf(field, values):
            guard (1...maximumFilterValues).contains(values.count) else {
                throw validationError(
                    "agent view in filters require 1 to \(maximumFilterValues) values"
                )
            }
            for value in values {
                try validate(field, value: value)
            }
        case let .exists(field):
            try validate(field)
        }
    }

    private static func validate(_ field: AgentViewField) throws {
        if case let .token(token) = field {
            try validateToken(token)
        }
    }

    private static func validate(_ field: AgentViewField, value: AgentViewValue) throws {
        try validate(field)
        switch (field, value) {
        case (.builtin(.workspaceID), .context(.currentWorkspaceID)),
             (.builtin(.tabID), .context(.currentTabID)),
             (.builtin(.seen), .bool),
             (.builtin(.stateChangeSequence), .number),
             (.token, .string):
            return
        case (_, .context):
            throw validationError(
                "agent view context type does not match the selected field"
            )
        case let (.builtin(field), .string(value)):
            switch field {
            case .status:
                guard AgentStatus(rawValue: value) != nil else {
                    throw validationError("unknown agent status `\(value)`")
                }
            case .workspaceID, .tabID, .paneID, .agent:
                break
            case .seen, .stateChangeSequence:
                throw validationError(
                    "agent view value type does not match the selected field"
                )
            }
        default:
            throw validationError(
                "agent view value type does not match the selected field"
            )
        }
    }

    private static func validate(_ field: AgentViewSortField) throws {
        if case let .token(token) = field {
            try validateToken(token)
        }
    }

    private static func validateToken(_ token: String) throws {
        let valid = !token.isEmpty
            && token.utf8.count <= 32
            && token.unicodeScalars.allSatisfy {
                ($0.isASCII && CharacterSet.alphanumerics.contains($0))
                    || "_-".unicodeScalars.contains($0)
            }
        guard valid else {
            throw validationError("invalid agent view token `\(token)`")
        }
    }

    private static func matches(
        _ record: AgentViewRecord,
        filter: AgentViewFilter,
        context: AgentViewEvaluationContext
    ) -> Bool {
        switch filter {
        case let .all(filters):
            return filters.allSatisfy { matches(record, filter: $0, context: context) }
        case let .any(filters):
            return filters.contains { matches(record, filter: $0, context: context) }
        case let .not(filter):
            return !matches(record, filter: filter, context: context)
        case let .equal(field, value):
            return fieldValue(record, field: field) == operandValue(value, context: context)
        case let .oneOf(field, values):
            let actual = fieldValue(record, field: field)
            return values.contains { actual == operandValue($0, context: context) }
        case let .exists(field):
            return fieldValue(record, field: field) != nil
        }
    }

    private static func fieldValue(
        _ record: AgentViewRecord,
        field: AgentViewField
    ) -> EvaluationValue? {
        switch field {
        case let .token(token):
            return record.tokens[token].map(EvaluationValue.string)
        case let .builtin(field):
            switch field {
            case .status: return .string(record.status.rawValue)
            case .workspaceID: return record.workspaceID.map(EvaluationValue.string)
            case .tabID: return record.tabID.map(EvaluationValue.string)
            case .paneID: return record.paneID.map(EvaluationValue.string)
            case .agent: return record.agent.map(EvaluationValue.string)
            case .seen: return .bool(record.seen)
            case .stateChangeSequence:
                return record.stateChangeSequence.map(EvaluationValue.number)
            }
        }
    }

    private static func operandValue(
        _ value: AgentViewValue,
        context: AgentViewEvaluationContext
    ) -> EvaluationValue? {
        switch value {
        case let .string(value): return .string(value)
        case let .bool(value): return .bool(value)
        case let .number(value): return .number(value)
        case .context(.currentWorkspaceID):
            return context.currentWorkspaceID.map(EvaluationValue.string)
        case .context(.currentTabID):
            return context.currentTabID.map(EvaluationValue.string)
        }
    }

    private static func compare(
        _ left: AgentViewRecord,
        _ right: AgentViewRecord,
        sorts: [AgentViewSort]
    ) -> Int {
        for sort in sorts {
            let ordering = compareOptional(
                sortValue(left, field: sort.field),
                sortValue(right, field: sort.field),
                order: sort.order
            )
            if ordering != 0 { return ordering }
        }
        return 0
    }

    private static func sortValue(
        _ record: AgentViewRecord,
        field: AgentViewSortField
    ) -> EvaluationValue? {
        switch field {
        case let .token(token):
            return record.tokens[token].map(EvaluationValue.string)
        case let .builtin(field):
            switch field {
            case .workspaceOrder:
                return record.workspaceOrder.map(EvaluationValue.number)
            case .tabOrder:
                return record.tabOrder.map(EvaluationValue.number)
            case .paneOrder:
                return record.paneOrder.map(EvaluationValue.number)
            case .attention:
                return .number(UInt64(AgentPanel.attentionPriority(record.status)))
            case .status:
                return .string(record.status.rawValue)
            case .agent:
                return record.agent.map(EvaluationValue.string)
            case .seen:
                return .bool(record.seen)
            case .stateChangeSequence:
                return record.stateChangeSequence.map(EvaluationValue.number)
            }
        }
    }

    private static func compareOptional(
        _ left: EvaluationValue?,
        _ right: EvaluationValue?,
        order: AgentViewSortOrder
    ) -> Int {
        switch (left, right) {
        case let (.some(left), .some(right)):
            let ordering = left.compare(to: right)
            return order == .descending ? -ordering : ordering
        case (.some, .none): return -1
        case (.none, .some): return 1
        case (.none, .none): return 0
        }
    }

    private static func compareNumbers(_ left: UInt64, _ right: UInt64) -> Int {
        left == right ? 0 : (left < right ? -1 : 1)
    }

    private static func compareOptionalNumbersDescending(
        _ left: UInt64?,
        _ right: UInt64?
    ) -> Int {
        compareOptional(
            left.map(EvaluationValue.number),
            right.map(EvaluationValue.number),
            order: .descending
        )
    }

    private static func stableSort(
        _ records: [AgentViewRecord],
        compare: (AgentViewRecord, AgentViewRecord) -> Int
    ) -> [AgentViewRecord] {
        records.enumerated()
            .sorted { left, right in
                let ordering = compare(left.element, right.element)
                return ordering == 0 ? left.offset < right.offset : ordering < 0
            }
            .map(\.element)
    }

    private static func validationError(_ message: String) -> AgentViewValidationError {
        AgentViewValidationError(message)
    }
}

private enum EvaluationValue: Equatable {
    case string(String)
    case bool(Bool)
    case number(UInt64)

    static func == (left: EvaluationValue, right: EvaluationValue) -> Bool {
        switch (left, right) {
        case let (.string(left), .string(right)):
            return left.utf8.elementsEqual(right.utf8)
        case let (.bool(left), .bool(right)):
            return left == right
        case let (.number(left), .number(right)):
            return left == right
        default:
            return false
        }
    }

    func compare(to other: EvaluationValue) -> Int {
        switch (self, other) {
        case let (.string(left), .string(right)):
            if left.utf8.elementsEqual(right.utf8) { return 0 }
            return left.utf8.lexicographicallyPrecedes(right.utf8) ? -1 : 1
        case let (.bool(left), .bool(right)):
            return left == right ? 0 : (!left && right ? -1 : 1)
        case let (.number(left), .number(right)):
            return left == right ? 0 : (left < right ? -1 : 1)
        case (.string, _): return -1
        case (.bool, .number): return -1
        case (.bool, .string), (.number, _): return 1
        }
    }
}
