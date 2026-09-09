import Foundation

public struct EndpointCommand: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let binding: String

    public init?(_ value: JSONValue) {
        guard let object = value.objectValue, let id = object["command_id"]?.stringValue,
              !id.isEmpty, id.utf8.count <= 4096 else { return nil }
        self.id = id
        title = object["description"]?.stringValue ?? object["action"]?.stringValue ?? id
        binding = object["binding_label"]?.stringValue ?? ""
    }
}

/// A menu captures its target before presentation. Later focus changes cannot redirect its action.
public struct EndpointCommandInvocation: Codable, Equatable, Sendable {
    public let command: EndpointCommand
    public let bootID: String
    public let workspaceID: String?
    public let tabID: String?
    public let paneID: String?

    public init(command: EndpointCommand, snapshot: HerdrEndpointSnapshot) {
        self.command = command
        bootID = snapshot.bootID
        workspaceID = snapshot.focusedWorkspaceID
        tabID = snapshot.focusedTabID
        paneID = snapshot.focusedPaneID
    }

    public func validate(in snapshot: HerdrEndpointSnapshot) throws {
        let matches = snapshot.commands.compactMap(EndpointCommand.init).filter { $0.id == command.id }
        guard bootID == snapshot.bootID, matches == [command],
              contains(workspaceID, key: "workspace_id", in: snapshot.workspaces),
              contains(tabID, key: "tab_id", in: snapshot.tabs, parent: ("workspace_id", workspaceID)),
              contains(paneID, key: "pane_id", in: snapshot.panes, parent: ("tab_id", tabID)) else {
            throw HerdrEndpointError.staleIdentity
        }
    }

    public var params: [String: JSONValue] {
        var result: [String: JSONValue] = ["command_id": .string(command.id)]
        if let workspaceID { result["workspace_id"] = .string(workspaceID) }
        if let tabID { result["tab_id"] = .string(tabID) }
        if let paneID { result["pane_id"] = .string(paneID) }
        return result
    }

    private func contains(_ id: String?, key: String, in resources: [JSONValue],
                          parent: (String, String?)? = nil) -> Bool {
        guard let id else { return true }
        let matches = resources.compactMap(\.objectValue).filter { $0[key]?.stringValue == id }
        guard matches.count == 1, let item = matches.first else { return false }
        guard let parent else { return true }
        return item[parent.0]?.stringValue == parent.1
    }
}
