import Foundation

public struct HerdrServerCapabilities: Codable, Equatable, Sendable {
    public let liveHandoff: Bool?
    public let detachedServerDaemon: Bool?
    public let endpointProtocolGeneration: Int?
    public let healthCheck: Bool?
    public let surfaceInterest: Bool?

    enum CodingKeys: String, CodingKey {
        case liveHandoff = "live_handoff"
        case detachedServerDaemon = "detached_server_daemon"
        case endpointProtocolGeneration = "endpoint_protocol_generation"
        case healthCheck = "health_check"
        case surfaceInterest = "surface_interest"
    }
}

public struct HerdrServerInfo: Codable, Equatable, Sendable {
    public let version: String
    public let `protocol`: Int
    public let capabilities: HerdrServerCapabilities?
}

/// Mac bridge operations and Herdr capabilities have separate version contracts.
public struct BridgeHostCapabilities: Codable, Equatable, Sendable {
    public let operations: [String]
    public let server: HerdrServerInfo?
    public let connectionID: String?

    public init(operations: [String], server: HerdrServerInfo?, connectionID: String? = nil) {
        self.operations = operations
        self.server = server
        self.connectionID = connectionID
    }

    public var supportsWorkspaceGroupClose: Bool {
        connectionID != nil && operations.contains(BridgeCapability.workspaceGroupClose) && (server?.protocol ?? 0) >= 22
    }

    public var supportsMuse: Bool {
        operations.contains(BridgeCapability.museAgent) && (server?.protocol ?? 0) >= 22
    }

    public var supportsAgentExplanation: Bool {
        connectionID != nil && operations.contains(BridgeCapability.agentExplanation) && server != nil
    }

    public var supportsIndependentPaneObservation: Bool {
        connectionID != nil && server != nil && operations.contains(BridgeCapability.independentPaneObservation)
    }

    public func supports(_ action: HerdrManagementAction) -> Bool {
        guard connectionID != nil, server != nil,
              operations.contains(BridgeCapability.herdrManagement) else { return false }
        switch action {
        case .updateClient: return true
        case .liveHandoff: return server?.capabilities?.liveHandoff == true
        case .stopServer: return operations.contains(BridgeCapability.herdrServerStop)
        }
    }
}
