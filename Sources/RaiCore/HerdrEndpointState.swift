import Foundation

struct EndpointHello: Encodable {
    struct Size: Encodable { let cols: UInt16; let rows: UInt16 }
    let generation = 1
    let cellWidthPx = 8
    let cellHeightPx = 16
    let surfaceSize = Size(cols: 80, rows: 24)
    let pixelMouse = true
    let directGraphics = false
    let endpointKeybindings = false
    let mouseCapture = false
    // Metadata negotiation never claims size ownership or activates a surface.
    let surfaceActive = false
    let snapshotCodecs = ["shell.snapshot.v1"]
    let surfaceCodecs = ["shell.surface.v1"]
    let inputCodecs = ["shell.input.semantic.v1"]
    let blobCodecs = ["shell.blob.v1"]
}

public struct HerdrEndpointWelcome: Decodable, Sendable, Equatable {
    public let generation: Int
    public let serverVersion: String
    public let methods: [String]
    public let capabilities: [String]

    enum CodingKeys: String, CodingKey {
        case generation, error, methods, capabilities
        case serverVersion = "server_version"
        case snapshotCodec = "snapshot_codec"
        case surfaceCodec = "surface_codec"
        case inputCodec = "input_codec"
        case blobCodec = "blob_codec"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let error = try values.decodeIfPresent(RPCErrorBody.self, forKey: .error) {
            throw HerdrEndpointError.incompatible(error.message)
        }
        generation = try values.decode(Int.self, forKey: .generation)
        guard generation == 1 else { throw HerdrEndpointError.incompatible("Unsupported generation \(generation).") }
        let codecs: [(CodingKeys, String)] = [(.snapshotCodec, "shell.snapshot.v1"), (.surfaceCodec, "shell.surface.v1"),
                                             (.inputCodec, "shell.input.semantic.v1"), (.blobCodec, "shell.blob.v1")]
        for (key, expected) in codecs {
            guard try values.decode(String.self, forKey: key) == expected else {
                throw HerdrEndpointError.incompatible("Unsupported \(key.rawValue).")
            }
        }
        serverVersion = try values.decode(String.self, forKey: .serverVersion)
        methods = try values.decodeIfPresent([String].self, forKey: .methods) ?? []
        capabilities = try values.decodeIfPresent([String].self, forKey: .capabilities) ?? []
    }
}

/// Endpoint snapshots describe one client view. They are not API session snapshots.
public struct HerdrEndpointSnapshot: Codable, Sendable, Equatable {
    public let bootID: String
    public let revision: UInt64
    public let focusedWorkspaceID: String?
    public let focusedTabID: String?
    public let focusedPaneID: String?
    public let commands: [JSONValue]
    public let releaseNotes: JSONValue?
    public let productAnnouncement: JSONValue?
    public let workspaces: [JSONValue]
    public let tabs: [JSONValue]
    public let panes: [JSONValue]
    public let agents: [JSONValue]
    public let agentViewLabel: String?
    public let agentOrder: [String]
    public let tabBarRight: [JSONValue]
    public let tabBarRightSeparator: String

    enum CodingKeys: String, CodingKey {
        case revision, commands, workspaces, tabs, panes, agents
        case agentViewLabel = "agent_view_label"
        case agentOrder = "agent_order"
        case tabBarRight = "tab_bar_right"
        case tabBarRightSeparator = "tab_bar_right_separator"
        case bootID = "boot_id"
        case focusedWorkspaceID = "focused_workspace_id"
        case focusedTabID = "focused_tab_id"
        case focusedPaneID = "focused_pane_id"
        case releaseNotes = "release_notes"
        case productAnnouncement = "product_announcement"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        bootID = try values.decode(String.self, forKey: .bootID)
        guard !bootID.isEmpty else { throw HerdrEndpointError.malformed }
        revision = try values.decode(UInt64.self, forKey: .revision)
        focusedWorkspaceID = try values.decodeIfPresent(String.self, forKey: .focusedWorkspaceID)
        focusedTabID = try values.decodeIfPresent(String.self, forKey: .focusedTabID)
        focusedPaneID = try values.decodeIfPresent(String.self, forKey: .focusedPaneID)
        commands = try values.decodeIfPresent([JSONValue].self, forKey: .commands) ?? []
        releaseNotes = try values.decodeIfPresent(JSONValue.self, forKey: .releaseNotes)
        productAnnouncement = try values.decodeIfPresent(JSONValue.self, forKey: .productAnnouncement)
        workspaces = try values.decodeIfPresent([JSONValue].self, forKey: .workspaces) ?? []
        tabs = try values.decodeIfPresent([JSONValue].self, forKey: .tabs) ?? []
        panes = try values.decodeIfPresent([JSONValue].self, forKey: .panes) ?? []
        agents = try values.decodeIfPresent([JSONValue].self, forKey: .agents) ?? []
        agentViewLabel = try values.decodeIfPresent(String.self, forKey: .agentViewLabel)
        agentOrder = try values.decodeIfPresent([String].self, forKey: .agentOrder) ?? []
        tabBarRight = try values.decodeIfPresent([JSONValue].self, forKey: .tabBarRight) ?? []
        tabBarRightSeparator = try values.decodeIfPresent(String.self, forKey: .tabBarRightSeparator) ?? " · "
    }
}

extension HerdrEndpointSnapshot {
    public var visibleAgents: [JSONValue] {
        guard agentViewLabel != nil else { return agents }
        var seen = Set<String>()
        return agentOrder.compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            let matches = agents.filter { $0.objectValue?["pane_id"]?.stringValue == id }
            return matches.count == 1 ? matches.first : nil
        }
    }
}
