import Foundation

public enum RemotePermissionDecision: String, Codable, Equatable, Sendable {
    case allow
    case deny
}

public struct PermissionDecisionAvailability: Equatable, Sendable {
    public let notificationAuthorized: Bool
    public let appIsForeground: Bool

    public init(notificationAuthorized: Bool, appIsForeground: Bool) {
        self.notificationAuthorized = notificationAuthorized
        self.appIsForeground = appIsForeground
    }

    public var available: Bool { notificationAuthorized || appIsForeground }

    public var capabilities: [String] {
        var values: [String] = []
        if available { values.append(BridgeCapability.permissionDecisions) }
        if notificationAuthorized { values.append(BridgeCapability.permissionDecisionPush) }
        return values
    }
}

public struct PendingDecision: Equatable, Sendable {
    public let requestID: String
    public let paneID: String
    public let toolName: String?
    public let toolInput: JSONValue?
    public let deadline: Date

    public init(
        requestID: String,
        paneID: String,
        toolName: String?,
        toolInput: JSONValue?,
        deadline: Date
    ) {
        self.requestID = requestID
        self.paneID = paneID
        self.toolName = toolName
        self.toolInput = toolInput
        self.deadline = deadline
    }
}
