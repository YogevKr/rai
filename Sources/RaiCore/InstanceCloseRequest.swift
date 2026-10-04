import Foundation

/// Capture the displayed instance and resources before a close menu or confirmation runs.
public struct InstanceCloseRequest: Identifiable, Sendable {
    public let id = UUID()
    public let workspace: InstanceWorkspace
    public let tabID: String?
    public let connectionID: String

    public init(workspace: InstanceWorkspace, tabID: String? = nil) throws {
        guard let connectionID = workspace.connectionID,
              tabID == nil || workspace.tabs.contains(where: { $0.id == tabID }) else {
            throw HerdrEndpointError.staleIdentity
        }
        self.workspace = workspace
        self.tabID = tabID
        self.connectionID = connectionID
    }

    public var method: String { tabID == nil ? "workspace.close" : "tab.close" }
    public var params: [String: JSONValue] {
        if let tabID { return ["tab_id": .string(tabID)] }
        return ["workspace_id": .string(workspace.id.workspaceID), "close_group": .bool(false)]
    }

    public func validate(_ snapshot: HerdrEndpointSnapshot) throws {
        guard snapshot.bootID == workspace.bootID,
              snapshot.workspaces.contains(where: {
                  $0.objectValue?["workspace_id"]?.stringValue == workspace.id.workspaceID
              }) else { throw HerdrEndpointError.staleIdentity }
        let currentTabs = snapshot.tabs.filter {
            $0.objectValue?["workspace_id"]?.stringValue == workspace.id.workspaceID
                && (tabID == nil || $0.objectValue?["tab_id"]?.stringValue == tabID)
        }.compactMap { $0.objectValue?["tab_id"]?.stringValue }
        let reviewedTabs = workspace.tabs.filter { tabID == nil || $0.id == tabID }
        guard Set(currentTabs) == Set(reviewedTabs.map(\.id)) else {
            throw HerdrEndpointError.staleIdentity
        }
        // A confirmation must not include a pane added after the user reviewed it.
        let currentPanes = snapshot.panes.filter {
            $0.objectValue?["workspace_id"]?.stringValue == workspace.id.workspaceID
                && (tabID == nil || $0.objectValue?["tab_id"]?.stringValue == tabID)
        }.compactMap { $0.objectValue?["pane_id"]?.stringValue }
        guard Set(currentPanes) == Set(reviewedTabs.flatMap(\.panes).map(\.paneID)) else {
            throw HerdrEndpointError.staleIdentity
        }
    }
}
