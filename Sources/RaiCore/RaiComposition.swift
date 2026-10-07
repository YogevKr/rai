import Foundation

public enum RaiCompositionLimits {
    public static let maxSpaces = 64
    public static let maxTabsPerSpace = 32
    public static let maxPanesPerTab = 16
    public static let maxTabs = 128
    public static let maxPaneSlots = 512
    public static let maxTextBytes = 256
    public static let maxEncodedBytes = 1_048_576
    public static let maxDismissedTabs = 4096
}

public enum RaiCompositionError: LocalizedError, Equatable, Sendable {
    case invalid(String)
    case duplicateIdentifier(UUID)
    case duplicateWorkspace(RaiWorkspaceReference)
    case duplicateSource(RaiPaneReference)
    case missingSpace(UUID)
    case missingTab(UUID)
    case missingSlot(UUID)
    case staleAttachment(UUID)
    case limitExceeded(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .duplicateIdentifier(let id): return "The Rai identifier is duplicated: \(id.uuidString)."
        case .duplicateWorkspace(let workspace):
            return "The Rai view contains the workspace more than once: \(workspace.workspaceID)."
        case .duplicateSource(let source):
            return "The Rai tab contains the pane more than once: \(source.paneID)."
        case .missingSpace(let id): return "The Rai space does not exist: \(id.uuidString)."
        case .missingTab(let id): return "The Rai tab does not exist: \(id.uuidString)."
        case .missingSlot(let id): return "The Rai pane slot does not exist: \(id.uuidString)."
        case .staleAttachment(let id): return "The Rai pane attachment is stale: \(id.uuidString)."
        case .limitExceeded(let name): return "The Rai view exceeds its \(name) limit."
        }
    }
}

/// A Herdr workspace address. Endpoint identity includes the machine profile and session.
public struct RaiWorkspaceReference: Codable, Hashable, Sendable {
    public let endpoint: MachineEndpoint
    public let workspaceID: String

    public init(endpoint: MachineEndpoint, workspaceID: String) {
        self.endpoint = endpoint
        self.workspaceID = workspaceID
    }

    public func validate() throws {
        try RaiCompositionValidation.endpoint(endpoint)
        try RaiCompositionValidation.text(workspaceID, name: "workspace identifier")
    }
}

/// A Herdr pane address. The address stays valid across Rai reconnects.
public struct RaiPaneReference: Codable, Hashable, Sendable {
    public let endpoint: MachineEndpoint
    public let workspaceID: String
    public let tabID: String
    public let paneID: String

    public init(endpoint: MachineEndpoint, workspaceID: String, tabID: String, paneID: String) {
        self.endpoint = endpoint
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.paneID = paneID
    }

    public var workspace: RaiWorkspaceReference {
        RaiWorkspaceReference(endpoint: endpoint, workspaceID: workspaceID)
    }

    public func validate() throws {
        try RaiCompositionValidation.endpoint(endpoint)
        try RaiCompositionValidation.text(workspaceID, name: "workspace identifier")
        try RaiCompositionValidation.text(tabID, name: "tab identifier")
        try RaiCompositionValidation.text(paneID, name: "pane identifier")
    }
}

/// Runtime identity for one endpoint connection. Rai does not persist this value.
public struct RaiPaneAttachment: Equatable, Sendable {
    public let connectionID: String
    public let bootID: String

    public init(connectionID: String, bootID: String) {
        self.connectionID = connectionID
        self.bootID = bootID
    }
}

/// The endpoint-qualified target for an action on a Rai pane slot.
public struct RaiPaneRoute: Equatable, Sendable {
    public let slotID: UUID
    public let source: RaiPaneReference
    public let connectionID: String
    public let bootID: String

    public init(slotID: UUID, source: RaiPaneReference, connectionID: String, bootID: String) {
        self.slotID = slotID
        self.source = source
        self.connectionID = connectionID
        self.bootID = bootID
    }
}

public struct RaiPaneSlot: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var label: String?
    public let source: RaiPaneReference
    public private(set) var attachment: RaiPaneAttachment?

    private enum CodingKeys: String, CodingKey {
        case id, label, source
    }

    public init(id: UUID = UUID(), label: String? = nil, source: RaiPaneReference) {
        self.id = id
        self.label = label
        self.source = source
        self.attachment = nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        source = try container.decode(RaiPaneReference.self, forKey: .source)
        attachment = nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encode(source, forKey: .source)
    }

    public func accepts(connectionID: String, bootID: String) -> Bool {
        attachment == RaiPaneAttachment(connectionID: connectionID, bootID: bootID)
    }

    fileprivate mutating func attach(connectionID: String, bootID: String) throws {
        try RaiCompositionValidation.runtime(connectionID: connectionID, bootID: bootID)
        attachment = RaiPaneAttachment(connectionID: connectionID, bootID: bootID)
    }

    fileprivate mutating func detach() {
        attachment = nil
    }
}

public struct RaiTab: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var label: String
    public var paneSlots: [RaiPaneSlot]

    public init(
        id: UUID = UUID(),
        label: String = "",
        paneSlots: [RaiPaneSlot] = []
    ) {
        self.id = id
        self.label = label
        self.paneSlots = paneSlots
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, paneSlots
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        paneSlots = try container.decode([RaiPaneSlot].self, forKey: .paneSlots)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(paneSlots, forKey: .paneSlots)
    }
}

public struct RaiSpace: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var label: String
    public let source: RaiWorkspaceReference
    public var tabs: [RaiTab]

    public init(id: UUID = UUID(), label: String = "", source: RaiWorkspaceReference, tabs: [RaiTab] = []) {
        self.id = id
        self.label = label
        self.source = source
        self.tabs = tabs
    }
}

/// A tab removed from Rai, scoped to one Herdr server incarnation.
public struct RaiDismissedTab: Codable, Hashable, Sendable {
    public let workspace: RaiWorkspaceReference
    public let bootID: String
    public let tabID: String

    public init(workspace: RaiWorkspaceReference, bootID: String, tabID: String) {
        self.workspace = workspace
        self.bootID = bootID
        self.tabID = tabID
    }
}

/// Rai-owned presentation state. Herdr remains the owner of every source pane.
public struct RaiComposition: Codable, Identifiable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let id: UUID
    public var label: String
    public var spaces: [RaiSpace]
    public var dismissedTabs: [RaiDismissedTab] = []

    public init(id: UUID = UUID(), label: String = "Default", spaces: [RaiSpace] = []) {
        self.id = id
        self.label = label
        self.spaces = spaces
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, label, spaces, dismissedTabs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.schemaVersion else {
            throw RaiCompositionError.invalid("The Rai composition schema is unsupported.")
        }
        id = try container.decode(UUID.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        spaces = try container.decode([RaiSpace].self, forKey: .spaces)
        dismissedTabs = try container.decodeIfPresent([RaiDismissedTab].self, forKey: .dismissedTabs) ?? []
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(spaces, forKey: .spaces)
        if !dismissedTabs.isEmpty { try container.encode(dismissedTabs, forKey: .dismissedTabs) }
    }

    public var tabs: [RaiTab] {
        spaces.flatMap(\.tabs)
    }

    public var paneSlots: [RaiPaneSlot] {
        tabs.flatMap(\.paneSlots)
    }

    public func space(id: UUID) -> RaiSpace? {
        spaces.first { $0.id == id }
    }

    public func tab(id: UUID) -> RaiTab? {
        tabs.first { $0.id == id }
    }

    public func paneSlot(id: UUID) -> RaiPaneSlot? {
        paneSlots.first { $0.id == id }
    }

    public func validate() throws {
        try RaiCompositionValidation.label(label, name: "view label")
        guard dismissedTabs.count <= RaiCompositionLimits.maxDismissedTabs else {
            throw RaiCompositionError.limitExceeded("dismissed tab")
        }
        for tab in dismissedTabs {
            try tab.workspace.validate()
            try RaiCompositionValidation.text(tab.bootID, name: "server boot identifier")
            try RaiCompositionValidation.text(tab.tabID, name: "tab identifier")
        }
        guard spaces.count <= RaiCompositionLimits.maxSpaces else {
            throw RaiCompositionError.limitExceeded("space")
        }

        var spaceIDs = Set<UUID>()
        var tabIDs = Set<UUID>()
        var slotIDs = Set<UUID>()
        var workspaceSources = Set<RaiWorkspaceReference>()
        var tabCount = 0
        var slotCount = 0

        for space in spaces {
            guard spaceIDs.insert(space.id).inserted else {
                throw RaiCompositionError.duplicateIdentifier(space.id)
            }
            try RaiCompositionValidation.label(space.label, name: "space label")
            try space.source.validate()
            guard workspaceSources.insert(space.source).inserted else {
                throw RaiCompositionError.duplicateWorkspace(space.source)
            }
        }

        for space in spaces {
            guard space.tabs.count <= RaiCompositionLimits.maxTabsPerSpace else {
                throw RaiCompositionError.limitExceeded("tabs per space")
            }

            for tab in space.tabs {
                guard tabIDs.insert(tab.id).inserted else {
                    throw RaiCompositionError.duplicateIdentifier(tab.id)
                }
                try RaiCompositionValidation.label(tab.label, name: "tab label")
                guard tab.paneSlots.count <= RaiCompositionLimits.maxPanesPerTab else {
                    throw RaiCompositionError.limitExceeded("panes per tab")
                }
                tabCount += 1
                var tabSources = Set<RaiPaneReference>()
                for slot in tab.paneSlots {
                    guard slotIDs.insert(slot.id).inserted else {
                        throw RaiCompositionError.duplicateIdentifier(slot.id)
                    }
                    if let label = slot.label {
                        try RaiCompositionValidation.label(label, name: "pane label")
                    }
                    try slot.source.validate()
                    guard tabSources.insert(slot.source).inserted else {
                        throw RaiCompositionError.duplicateSource(slot.source)
                    }
                    guard workspaceSources.contains(slot.source.workspace) else {
                        throw RaiCompositionError.invalid(
                            "The pane source is not registered by a Rai space."
                        )
                    }
                    slotCount += 1
                }
            }
        }

        guard tabCount <= RaiCompositionLimits.maxTabs else {
            throw RaiCompositionError.limitExceeded("tab")
        }
        guard slotCount <= RaiCompositionLimits.maxPaneSlots else {
            throw RaiCompositionError.limitExceeded("pane slot")
        }
    }

    public mutating func addSpace(_ space: RaiSpace) throws {
        spaces.append(space)
        do {
            try validate()
        } catch {
            spaces.removeLast()
            throw error
        }
    }

    public mutating func addTab(_ tab: RaiTab, to spaceID: UUID) throws {
        guard let index = spaces.firstIndex(where: { $0.id == spaceID }) else {
            throw RaiCompositionError.missingSpace(spaceID)
        }
        spaces[index].tabs.append(tab)
        do {
            try validate()
        } catch {
            spaces[index].tabs.removeLast()
            throw error
        }
    }

    public mutating func addPaneSlot(_ slot: RaiPaneSlot, to tabID: UUID) throws {
        guard let spaceIndex = spaces.firstIndex(where: { $0.tabs.contains { $0.id == tabID } }),
              let tabIndex = spaces[spaceIndex].tabs.firstIndex(where: { $0.id == tabID }) else {
            throw RaiCompositionError.missingTab(tabID)
        }
        spaces[spaceIndex].tabs[tabIndex].paneSlots.append(slot)
        do {
            try validate()
        } catch {
            spaces[spaceIndex].tabs[tabIndex].paneSlots.removeLast()
            throw error
        }
    }

    public mutating func attachPaneSlot(
        id: UUID,
        connectionID: String,
        bootID: String
    ) throws {
        guard let spaceIndex = spaces.firstIndex(where: { $0.tabs.contains { $0.paneSlots.contains { $0.id == id } } }),
              let tabIndex = spaces[spaceIndex].tabs.firstIndex(where: { $0.paneSlots.contains { $0.id == id } }),
              let slotIndex = spaces[spaceIndex].tabs[tabIndex].paneSlots.firstIndex(where: { $0.id == id }) else {
            throw RaiCompositionError.missingSlot(id)
        }
        try spaces[spaceIndex].tabs[tabIndex].paneSlots[slotIndex].attach(
            connectionID: connectionID, bootID: bootID
        )
    }

    public mutating func detachPaneSlot(id: UUID) throws {
        guard let spaceIndex = spaces.firstIndex(where: { $0.tabs.contains { $0.paneSlots.contains { $0.id == id } } }),
              let tabIndex = spaces[spaceIndex].tabs.firstIndex(where: { $0.paneSlots.contains { $0.id == id } }),
              let slotIndex = spaces[spaceIndex].tabs[tabIndex].paneSlots.firstIndex(where: { $0.id == id }) else {
            throw RaiCompositionError.missingSlot(id)
        }
        spaces[spaceIndex].tabs[tabIndex].paneSlots[slotIndex].detach()
    }

    public func routePaneSlot(
        id: UUID,
        endpoint: MachineEndpoint,
        connectionID: String,
        bootID: String
    ) throws -> RaiPaneRoute {
        guard let slot = paneSlot(id: id) else { throw RaiCompositionError.missingSlot(id) }
        guard slot.source.endpoint == endpoint, slot.accepts(connectionID: connectionID, bootID: bootID) else {
            throw RaiCompositionError.staleAttachment(id)
        }
        return RaiPaneRoute(slotID: id, source: slot.source, connectionID: connectionID, bootID: bootID)
    }
}

public struct RaiCompositionStore: Sendable {
    public static let defaultFileName = "mixed-view.json"
    public let fileURL: URL

    public init(paths: AppDataPaths = .current) {
        fileURL = paths.applicationSupport
            .appendingPathComponent("compositions", isDirectory: true)
            .appendingPathComponent(Self.defaultFileName)
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> RaiComposition? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        guard data.count <= RaiCompositionLimits.maxEncodedBytes else {
            throw RaiCompositionError.limitExceeded("encoded composition")
        }
        return try JSONDecoder().decode(RaiComposition.self, from: data)
    }

    public func save(_ composition: RaiComposition) throws {
        try composition.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(composition)
        guard data.count <= RaiCompositionLimits.maxEncodedBytes else {
            throw RaiCompositionError.limitExceeded("encoded composition")
        }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}

private enum RaiCompositionValidation {
    static func label(_ value: String, name: String) throws {
        guard value.utf8.count <= RaiCompositionLimits.maxTextBytes,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw RaiCompositionError.invalid("The \(name) is invalid.")
        }
    }

    static func text(_ value: String, name: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf8.count <= RaiCompositionLimits.maxTextBytes,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw RaiCompositionError.invalid("The \(name) is invalid.")
        }
    }

    static func endpoint(_ endpoint: MachineEndpoint) throws {
        try text(endpoint.session, name: "session")
        if let profileID = endpoint.profileID {
            try text(profileID, name: "machine profile")
        }
    }

    static func runtime(connectionID: String, bootID: String) throws {
        try text(connectionID, name: "connection identifier")
        try text(bootID, name: "server boot identifier")
    }
}
