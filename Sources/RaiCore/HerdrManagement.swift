import Foundation

public enum HerdrManagementAction: String, Codable, Sendable, CaseIterable {
    case updateClient
    case liveHandoff
    case stopServer

    public var title: String {
        switch self {
        case .updateClient: "Update Herdr Client"
        case .liveHandoff: "Hand Off Live Server"
        case .stopServer: "Stop Herdr Server"
        }
    }

    public var effects: String {
        switch self {
        case .updateClient:
            "Update the Herdr installation on this Mac. Rai retains a compatible client for the running server."
        case .stopServer:
            "Stop the selected session and all its panes. Running commands and agents will end. This cannot be undone."
        case .liveHandoff:
            "Replace this session's server with the installed Herdr version. Live panes continue. Connected views reconnect."
        }
    }
}

public struct HerdrManagementRequest: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let action: HerdrManagementAction
    public let connectionID: String

    public init(id: String = UUID().uuidString, action: HerdrManagementAction, connectionID: String) {
        self.id = id
        self.action = action
        self.connectionID = connectionID
    }
}

public struct HerdrManagementResult: Codable, Equatable, Sendable {
    public let request: HerdrManagementRequest
    public let text: String

    public init(request: HerdrManagementRequest, text: String) {
        self.request = request
        self.text = text
    }
}
