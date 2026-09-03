import Foundation

public enum RemotePermissionDecision: String, Codable, Equatable, Sendable {
    case allow
    case deny
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
