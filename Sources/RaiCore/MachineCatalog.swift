import Foundation

/// Labels never form part of a resource address.
public struct MachineEndpoint: Codable, Hashable, Sendable {
    public let profileID: String?
    public let session: String
    public init(profileID: String? = nil, session: String) {
        self.profileID = profileID; self.session = session
    }
}

public struct MachineResource: Codable, Hashable, Sendable {
    public let endpoint: MachineEndpoint
    public let connectionID: String
    public let bootID: String
    public let paneID: String
    public init(endpoint: MachineEndpoint, connectionID: String, bootID: String, paneID: String) {
        self.endpoint = endpoint; self.connectionID = connectionID
        self.bootID = bootID; self.paneID = paneID
    }
}

public struct SavedMachine: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let target: String
    public let session: String
    public let enabled: Bool
    public let selected: Bool
    public var endpoint: MachineEndpoint { .init(profileID: id, session: session) }
}

public enum MachineOperation: Codable, Equatable, Sendable {
    case refresh
    case reconnect(MachineEndpoint)
    case add(target: String, label: String, session: String)
    case rename(profileID: String, label: String)
    case remove(profileID: String)
    case enable(profileID: String)
    case disable(profileID: String)
    case answerSetup(id: UUID, promptID: UUID, approve: Bool)
    case cancelSetup(UUID)

    public func arguments() throws -> [String] {
        switch self {
        case .refresh: return ["machine", "list", "--json"]
        case .reconnect, .answerSetup, .cancelSetup:
            throw MachineCatalogError.invalid("This operation does not modify saved machines through the CLI.")
        case .add(let target, let label, let session):
            try Self.validateTarget(target)
            try Self.validateLabel(label)
            try Self.validateSession(session)
            return ["machine", "add", target, "--label", label, "--remote-session", session]
        case .rename(let id, let label):
            try Self.validateProfile(id); try Self.validateLabel(label)
            return ["machine", "rename", id, "--label", label]
        case .remove(let id): return try Self.profileArguments("remove", id)
        case .enable(let id): return try Self.profileArguments("enable", id)
        case .disable(let id): return try Self.profileArguments("disable", id)
        }
    }

    private static func profileArguments(_ action: String, _ id: String) throws -> [String] {
        try validateProfile(id)
        return ["machine", action, id]
    }

    static func validateProfile(_ value: String) throws {
        guard value.utf8.count == 32, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw MachineCatalogError.invalid("The machine identifier is invalid.")
        }
    }

    static func validateLabel(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf8.count <= 128, value.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw MachineCatalogError.invalid("Enter a machine label with at most 128 bytes and no control characters.")
        }
    }

    static func validateTarget(_ value: String) throws {
        let authority = value.hasPrefix("ssh://") ? String(value.dropFirst(6)) : value
        guard !value.isEmpty, !value.hasPrefix("-"), value.utf8.count <= 1024,
              value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              !authority.split(separator: "@").dropLast().joined().contains(":") else {
            throw MachineCatalogError.invalid("Enter an SSH target without a password, spaces, or control characters.")
        }
    }

    static func validateSession(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 64, value != ".", value != "..",
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,95].contains($0) }) else {
            throw MachineCatalogError.invalid("Enter a session name with letters, numbers, dots, underscores, or hyphens.")
        }
    }
}

public enum MachineCatalogError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let message): return message } }
}

public enum MachineCatalog {
    public static func parse(_ data: Data) throws -> [SavedMachine] {
        guard data.count <= 131_072 else { throw MachineCatalogError.invalid("The machine list is too large.") }
        let machines = try JSONDecoder().decode([SavedMachine].self, from: data)
        guard machines.count <= 64, Set(machines.map(\.id)).count == machines.count else {
            throw MachineCatalogError.invalid("The machine list has duplicate identifiers or too many entries.")
        }
        for machine in machines {
            try MachineOperation.validateProfile(machine.id)
            try MachineOperation.validateLabel(machine.label)
            try MachineOperation.validateTarget(machine.target)
            try MachineOperation.validateSession(machine.session)
        }
        return machines
    }
}

public struct MachineAgent: Codable, Equatable, Identifiable, Sendable {
    public let resource: MachineResource
    public let name: String
    public let agent: String
    public let status: String
    public var id: MachineResource { resource }
    public init(resource: MachineResource, name: String, agent: String, status: String) {
        self.resource = resource; self.name = name; self.agent = agent; self.status = status
    }
}

public struct MachineEntry: Codable, Equatable, Identifiable, Sendable {
    public enum Health: String, Codable, Sendable { case connecting, online, disconnected, disabled }
    public let endpoint: MachineEndpoint
    public var label: String
    public var connectionID: String?
    public var health: Health
    public var error: String?
    public var agents: [MachineAgent]
    public var target: String?
    public var id: MachineEndpoint { endpoint }
    public init(endpoint: MachineEndpoint, label: String, connectionID: String? = nil,
                health: Health = .disconnected, error: String? = nil, agents: [MachineAgent] = [], target: String? = nil) {
        self.endpoint = endpoint; self.label = label; self.connectionID = connectionID
        self.health = health; self.error = error; self.agents = agents; self.target = target
    }
}

extension MachineEntry {
    public var addressLabel: String { "\(target ?? "This Mac") · \(endpoint.session)" }

    public func matchingAgents(query: String, status: String) -> [MachineAgent] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return agents.filter { agent in
            (status == "All" || status == agent.status)
                && (query.isEmpty || [label, target ?? "", endpoint.session, agent.name, agent.agent, agent.status]
                    .contains { $0.localizedCaseInsensitiveContains(query) })
        }
    }
}

public struct MachineDirectoryState: Codable, Equatable, Sendable {
    public var revision: UUID
    public var entries: [MachineEntry]
    public var busy: Bool
    public var error: String?
    public var setup: MachineSetupState?
    public init(revision: UUID = UUID(), entries: [MachineEntry] = [], busy: Bool = false, error: String? = nil,
                setup: MachineSetupState? = nil) {
        self.revision = revision; self.entries = entries; self.busy = busy; self.error = error; self.setup = setup
    }
    public func entry(for endpoint: MachineEndpoint) -> MachineEntry? { entries.first { $0.endpoint == endpoint } }
}

public struct MachineSetupState: Codable, Equatable, Sendable {
    public let id: UUID
    public let target: String
    public let label: String
    public let session: String
    public var output: String
    public var promptID: UUID?
    public var finished: Bool
    public init(id: UUID, target: String, label: String, session: String, output: String = "",
                promptID: UUID? = nil, finished: Bool = false) {
        self.id = id; self.target = target; self.label = label; self.session = session
        self.output = output; self.promptID = promptID; self.finished = finished
    }
}

public struct MachineRequest: Codable, Equatable, Sendable {
    public let id: UUID
    public let revision: UUID
    public let operation: MachineOperation
    public init(id: UUID = UUID(), revision: UUID, operation: MachineOperation) {
        self.id = id; self.revision = revision; self.operation = operation
    }
}
