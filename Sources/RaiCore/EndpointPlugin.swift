import Foundation

public enum EndpointPluginOperation: Codable, Equatable, Sendable {
    case list
    case enable(String), disable(String), unlink(String), uninstall(String)
    case integrations, installIntegration(String)
    case setAgentView(AgentViewSetParams), clearAgentView
    case activateLink(EndpointPluginLinkInvocation)
    case openPane(EndpointPluginPaneInvocation)
    case prepareInstall(source: String, reference: String)
    case confirmInstall(UUID), cancelInstall(UUID)

    public var endpointMethod: String? {
        switch self {
        case .integrations: "integration.list"
        case .installIntegration: "integration.install"
        case .activateLink: "pane.link.activate"
        case .openPane: "plugin.pane.open"
        default: nil
        }
    }

    public func rpc() throws -> (method: String, params: [String: JSONValue]) {
        switch self {
        case .list: return ("plugin.list", [:])
        case .enable(let id): return ("plugin.enable", try pluginID(id))
        case .disable(let id): return ("plugin.disable", try pluginID(id))
        case .unlink(let id): return ("plugin.unlink", try pluginID(id))
        case .integrations: return ("integration.list", [:])
        case .installIntegration(let target):
            guard Self.integrationTargets.contains(target) else { throw HerdrEndpointError.malformed }
            return ("integration.install", ["target": .string(target)])
        case .setAgentView(let spec):
            let validated = try AgentViewEvaluator.validate(spec)
            let encoded = try JSONEncoder().encode(validated)
            return ("agent.view.set", try JSONDecoder().decode([String: JSONValue].self, from: encoded))
        case .clearAgentView: return ("agent.view.clear", [:])
        case .activateLink(let link): return ("pane.link.activate", link.params)
        case .openPane(let pane):
            var params = try pluginID(pane.pluginID)
            _ = try pluginID(pane.entrypoint)
            params["entrypoint"] = .string(pane.entrypoint)
            params["focus"] = .bool(true)
            return ("plugin.pane.open", params)
        default: throw HerdrEndpointError.incompatible("This operation requires a reviewed plugin install on the host.")
        }
    }

    private func pluginID(_ id: String) throws -> [String: JSONValue] {
        guard !id.isEmpty, id.utf8.count <= 1024, !id.unicodeScalars.contains(where: { $0.value < 32 }) else {
            throw HerdrEndpointError.malformed
        }
        return ["plugin_id": .string(id)]
    }

    public static let integrationTargets = ["pi", "omp", "claude", "codex", "copilot", "devin", "droid", "kimi", "opencode", "kilo", "hermes", "qodercli", "qwen", "cursor", "mastracode", "antigravity_cli", "grok"]
}

public struct EndpointPluginRequest: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let bootID: String
    public let operation: EndpointPluginOperation
    public init(bootID: String, operation: EndpointPluginOperation) { id = UUID(); self.bootID = bootID; self.operation = operation }
}

public struct EndpointPluginResult: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let value: JSONValue?
    public let error: String?
    public init(requestID: UUID, value: JSONValue? = nil, error: String? = nil) {
        self.requestID = requestID; self.value = value; self.error = error
    }
}

public struct EndpointInstalledPlugin: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let description: String?
    public let enabled: Bool
    public let source: JSONValue?
    public let details: [String: JSONValue]

    public init?(_ value: JSONValue) {
        guard let data = value.objectValue, let id = data["plugin_id"]?.stringValue,
              let name = data["name"]?.stringValue, case .bool(let enabled) = data["enabled"] else { return nil }
        self.id = id; self.name = name; self.enabled = enabled
        version = data["version"]?.stringValue ?? ""
        description = data["description"]?.stringValue
        source = data["source"]
        details = data
    }

    public var panes: [EndpointPluginPane] {
        guard case .array(let entries) = details["panes"] else { return [] }
        let panes = entries.compactMap(EndpointPluginPane.init)
        return Set(panes.map(\.id)).count == panes.count ? panes : []
    }

    public static func list(_ result: JSONValue) throws -> [Self] {
        guard case .array(let items) = result.objectValue?["plugins"] else { throw HerdrEndpointError.malformed }
        let plugins = items.compactMap(Self.init)
        guard plugins.count == items.count, Set(plugins.map(\.id)).count == plugins.count else { throw HerdrEndpointError.malformed }
        return plugins
    }
}

public struct EndpointPluginPane: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String

    public init?(_ value: JSONValue) {
        guard let entry = value.objectValue, let id = entry["id"]?.stringValue,
              !id.isEmpty, id.utf8.count <= 1024,
              !id.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }) else { return nil }
        self.id = id
        title = entry["title"]?.stringValue ?? id
    }
}

/// Popup placement follows the native client's current pane, never the generic API's global focus.
public struct EndpointPluginPaneInvocation: Codable, Equatable, Sendable {
    public let pluginID: String
    public let entrypoint: String
    public let bootID: String
    public let projectionRevision: UInt64
    public let workspaceID: String?
    public let tabID: String?
    public let paneID: String

    public init?(plugin: EndpointInstalledPlugin, pane: EndpointPluginPane, snapshot: HerdrEndpointSnapshot) {
        guard plugin.enabled, plugin.panes.contains(pane), let paneID = snapshot.focusedPaneID, !paneID.isEmpty else { return nil }
        pluginID = plugin.id; entrypoint = pane.id
        bootID = snapshot.bootID; projectionRevision = snapshot.revision
        workspaceID = snapshot.focusedWorkspaceID; tabID = snapshot.focusedTabID
        self.paneID = paneID
    }

    public func validate(in snapshot: HerdrEndpointSnapshot) throws {
        guard bootID == snapshot.bootID, projectionRevision <= snapshot.revision,
              workspaceID == snapshot.focusedWorkspaceID, tabID == snapshot.focusedTabID,
              paneID == snapshot.focusedPaneID else { throw HerdrEndpointError.staleIdentity }
    }
}
