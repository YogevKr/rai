import Foundation

public struct AgentExplanation: Codable, Equatable, Identifiable, Sendable {
    public let paneID: String
    public let requestID: String
    public let connectionID: String
    public var text: String?
    public var id: String { requestID }

    public init(paneID: String, requestID: String, connectionID: String, text: String? = nil) {
        self.paneID = paneID
        self.requestID = requestID
        self.connectionID = connectionID
        self.text = text
    }

    public func accepts(_ response: AgentExplanation, connectionID: String?) -> Bool {
        requestID == response.requestID && paneID == response.paneID
            && self.connectionID == response.connectionID && self.connectionID == connectionID
    }
}
