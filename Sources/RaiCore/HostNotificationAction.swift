import Foundation

public struct HostNotificationAction: Codable, Equatable, Sendable {
    public enum Operation: Codable, Equatable, Sendable {
        case input(bytesBase64: String)
        case decide(requestID: String, decision: RemotePermissionDecision)
    }
    public let connectionID: String
    public let paneID: String
    public let operation: Operation
    public init(connectionID: String, paneID: String, operation: Operation) {
        self.connectionID = connectionID; self.paneID = paneID; self.operation = operation
    }
    public func isAllowed(currentConnectionID: String?, remote: Bool) -> Bool {
        !remote && !connectionID.isEmpty && connectionID == currentConnectionID
            && !paneID.isEmpty && paneID.utf8.count <= 512
    }
}
