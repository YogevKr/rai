import Foundation

public enum EndpointLayoutAction: Codable, Equatable, Sendable {
    case resize(paneID: String, direction: EndpointBridgeCommand.Direction)
    case movePane(paneID: String, destination: PaneMoveDestination)
    case moveTab(tabID: String, beforeTabID: String?)
    case moveWorkspace(workspaceID: String, beforeWorkspaceID: String?)
    case closeWorkspace(WorkspaceClosePreview)

    public var method: String {
        switch self {
        case .resize: return "pane.resize"
        case .movePane: return "pane.move"
        case .moveTab: return "tab.move"
        case .moveWorkspace: return "workspace.move"
        case .closeWorkspace: return "workspace.close"
        }
    }
}

/// Keep topology identity while allowing unrelated output and focus changes.
public struct EndpointLayoutRequest: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let bootID: String
    public let owningViewID: UUID
    public let action: EndpointLayoutAction
    public let workspaceID: String
    public let tabID: String?
    public let destinationWorkspaceID: String?
    public let capturedOrder: [String]

    public init(snapshot: HerdrEndpointSnapshot, owningViewID: UUID, action: EndpointLayoutAction, id: UUID = UUID()) throws {
        self.id = id; bootID = snapshot.bootID; self.action = action; self.owningViewID = owningViewID
        let tab: String?
        let workspace: String?
        switch action {
        case .resize(let pane, _), .movePane(let pane, _):
            let item = try Self.item(pane, key: "pane_id", in: snapshot.panes)
            tab = item["tab_id"]?.stringValue; workspace = item["workspace_id"]?.stringValue
        case .moveTab(let target, _):
            tab = target
            workspace = try Self.item(target, key: "tab_id", in: snapshot.tabs)["workspace_id"]?.stringValue
        case .moveWorkspace(let target, _): tab = nil; workspace = target
        case .closeWorkspace(let preview): tab = nil; workspace = preview.workspaceID
        }
        guard let workspace else { throw HerdrEndpointError.staleIdentity }
        workspaceID = workspace; tabID = tab
        if case .movePane(_, .tab(let target, _, _)) = action {
            destinationWorkspaceID = try Self.item(target, key: "tab_id", in: snapshot.tabs)["workspace_id"]?.stringValue
        } else { destinationWorkspaceID = nil }
        switch action {
        case .moveTab: capturedOrder = Self.tabOrder(snapshot, workspaceID: workspace)
        case .moveWorkspace: capturedOrder = snapshot.workspaces.compactMap { $0.objectValue?["workspace_id"]?.stringValue }
        default: capturedOrder = []
        }
        try validate(in: snapshot)
    }

    public func validate(in snapshot: HerdrEndpointSnapshot) throws {
        guard bootID == snapshot.bootID else { throw HerdrEndpointError.staleIdentity }
        _ = try Self.item(workspaceID, key: "workspace_id", in: snapshot.workspaces)
        if let tabID {
            guard try Self.item(tabID, key: "tab_id", in: snapshot.tabs)["workspace_id"]?.stringValue == workspaceID else {
                throw HerdrEndpointError.staleIdentity
            }
        }
        switch action {
        case .resize(let pane, _), .movePane(let pane, _):
            let item = try Self.item(pane, key: "pane_id", in: snapshot.panes)
            guard item["workspace_id"]?.stringValue == workspaceID, item["tab_id"]?.stringValue == tabID else {
                throw HerdrEndpointError.staleIdentity
            }
            if case .movePane(_, let destination) = action { try validate(destination, in: snapshot) }
        case .moveTab(let target, let before):
            guard target == tabID, capturedOrder == Self.tabOrder(snapshot, workspaceID: workspaceID) else {
                throw HerdrEndpointError.staleIdentity
            }
            try validateOrder(target: target, before: before)
        case .moveWorkspace(let target, let before):
            guard target == workspaceID,
                  capturedOrder == snapshot.workspaces.compactMap({ $0.objectValue?["workspace_id"]?.stringValue }) else {
                throw HerdrEndpointError.staleIdentity
            }
            try validateOrder(target: target, before: before)
        case .closeWorkspace(let preview):
            guard preview.workspaceID == workspaceID, preview.connectionID == bootID else { throw HerdrEndpointError.staleIdentity }
            // Native endpoint workspace.close uses Herdr 0.9's explicit close_group contract.
            try preview.validate(against: Self.workspaces(snapshot), supportsGroupClosure: true, connectionID: bootID)
            try validateClosureProgress(in: snapshot, closed: [])
        }
    }

    public func validateClosureProgress(in snapshot: HerdrEndpointSnapshot, closed: [String]) throws {
        guard bootID == snapshot.bootID, case .closeWorkspace(let preview) = action,
              Set(closed).isSubset(of: Set(preview.workspaceIDs)) else { throw HerdrEndpointError.staleIdentity }
        let current = try Self.workspaces(snapshot)
        let remaining = preview.workspaces.filter { !closed.contains($0.workspaceID) }
        for reviewed in remaining {
            let matches = current.filter { $0.workspaceID == reviewed.workspaceID }
            guard matches.count == 1,
                  matches[0].worktree?.repoKey == reviewed.worktree?.repoKey,
                  matches[0].worktree?.isLinkedWorktree == reviewed.worktree?.isLinkedWorktree else {
                throw HerdrEndpointError.staleIdentity
            }
        }
        if preview.closeGroup {
            let currentIDs = Set(WorkspaceClosePreview.group(in: current, workspaceID: workspaceID).map(\.workspaceID)).subtracting(closed)
            guard currentIDs == Set(remaining.map(\.workspaceID)) else { throw HerdrEndpointError.staleIdentity }
        }
    }

    public var rpc: (method: String, params: [String: JSONValue]) {
        let params: [String: JSONValue]
        switch action {
        case .resize(let pane, let direction):
            params = ["pane_id": .string(pane), "direction": .string(direction.rawValue), "amount": .number(0.05)]
        case .movePane(let pane, let destination):
            params = ["pane_id": .string(pane), "destination": destination.jsonValue, "focus": .bool(false)]
        case .moveTab(let tab, let before):
            params = ["tab_id": .string(tab), "insert_index": .number(Double(before.flatMap { capturedOrder.firstIndex(of: $0) } ?? capturedOrder.count))]
        case .moveWorkspace(let workspace, let before):
            params = ["workspace_id": .string(workspace), "insert_index": .number(Double(before.flatMap { capturedOrder.firstIndex(of: $0) } ?? capturedOrder.count))]
        case .closeWorkspace(let preview):
            params = ["workspace_id": .string(preview.workspaceID), "close_group": .bool(false)]
        }
        return (action.method, params)
    }

    public static func workspaces(_ snapshot: HerdrEndpointSnapshot) throws -> [Workspace] {
        try snapshot.workspaces.map { value in
            guard var row = value.objectValue, let id = row["workspace_id"]?.stringValue else { throw HerdrEndpointError.malformed }
            row["pane_count"] = row["pane_count"] ?? .number(Double(snapshot.panes.filter { $0.objectValue?["workspace_id"]?.stringValue == id }.count))
            row["tab_count"] = row["tab_count"] ?? .number(Double(snapshot.tabs.filter { $0.objectValue?["workspace_id"]?.stringValue == id }.count))
            if let projected = row["worktree"]?.objectValue, let key = projected["key"] {
                // Endpoint worktrees expose group identity, not filesystem checkout paths.
                row["worktree"] = .object(["repo_key": key, "repo_name": projected["label"] ?? .string(""),
                                          "checkout_path": .string(""), "is_linked_worktree": projected["is_linked_worktree"] ?? .null])
            }
            return try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(JSONValue.object(row)))
        }
    }

    private static func item(_ id: String, key: String, in records: [JSONValue]) throws -> [String: JSONValue] {
        let matches = records.compactMap(\.objectValue).filter { $0[key]?.stringValue == id }
        guard matches.count == 1, let item = matches.first, !id.isEmpty else { throw HerdrEndpointError.staleIdentity }
        return item
    }

    private static func tabOrder(_ snapshot: HerdrEndpointSnapshot, workspaceID: String) -> [String] {
        snapshot.tabs.compactMap { item in
            guard item.objectValue?["workspace_id"]?.stringValue == workspaceID else { return nil }
            return item.objectValue?["tab_id"]?.stringValue
        }
    }

    private func validateOrder(target: String, before: String?) throws {
        guard capturedOrder.contains(target), Set(capturedOrder).count == capturedOrder.count,
              before == nil || (before != target && capturedOrder.contains(before!)) else { throw HerdrEndpointError.staleIdentity }
    }

    private func validate(_ destination: PaneMoveDestination, in snapshot: HerdrEndpointSnapshot) throws {
        switch destination {
        case .tab(let target, _, let pane):
            let tab = try Self.item(target, key: "tab_id", in: snapshot.tabs)
            guard target != tabID, let destinationWorkspaceID, tab["workspace_id"]?.stringValue == destinationWorkspaceID,
                  let pane else { throw HerdrEndpointError.staleIdentity }
            let item = try Self.item(pane, key: "pane_id", in: snapshot.panes)
            guard item["tab_id"]?.stringValue == target, item["workspace_id"]?.stringValue == destinationWorkspaceID else {
                throw HerdrEndpointError.staleIdentity
            }
        case .newTab(let workspace, let label):
            guard let workspace, label == nil else { throw HerdrEndpointError.malformed }
            _ = try Self.item(workspace, key: "workspace_id", in: snapshot.workspaces)
        case .newWorkspace(let label, let tabLabel):
            guard label == nil, tabLabel == nil else { throw HerdrEndpointError.malformed }
        }
    }
}

public struct EndpointLayoutResult: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let message: String
    public let failed: Bool
    public init(requestID: UUID, message: String, failed: Bool = false) {
        self.requestID = requestID; self.message = message; self.failed = failed
    }

    public static func movedPane(in value: JSONValue, request: EndpointLayoutRequest) throws -> String? {
        guard value.objectValue?["type"]?.stringValue == "pane_move",
              let outcome = value.objectValue?["move_result"]?.objectValue,
              let changed = outcome["changed"] else { throw HerdrEndpointError.malformed }
        if changed == .bool(false) { return nil }
        guard changed == .bool(true), case .movePane(let source, let destination) = request.action,
              outcome["previous_pane_id"]?.stringValue == source,
              outcome["previous_workspace_id"]?.stringValue == request.workspaceID,
              outcome["previous_tab_id"]?.stringValue == request.tabID,
              let pane = outcome["pane"]?.objectValue, let workspace = pane["workspace_id"]?.stringValue,
              let tab = pane["tab_id"]?.stringValue, !workspace.isEmpty, !tab.isEmpty,
              let id = pane["pane_id"]?.stringValue, !id.isEmpty else { throw HerdrEndpointError.malformed }
        switch destination {
        case .tab(let target, _, _):
            guard tab == target, workspace == request.destinationWorkspaceID else { throw HerdrEndpointError.staleIdentity }
        case .newTab(let target, _):
            guard workspace == target, tab != request.tabID else { throw HerdrEndpointError.staleIdentity }
        case .newWorkspace:
            guard workspace != request.workspaceID else { throw HerdrEndpointError.staleIdentity }
        }
        return id
    }

    public static func changed(in value: JSONValue, request: EndpointLayoutRequest) throws -> Bool {
        let object = value.objectValue ?? [:]
        if case .resize(let pane, _) = request.action {
            guard object["type"]?.stringValue == "pane_resize", let resize = object["resize"]?.objectValue,
                  resize["pane_id"]?.stringValue == pane, let changed = resize["changed"],
                  changed == .bool(true) || changed == .bool(false) else { throw HerdrEndpointError.malformed }
            return changed == .bool(true)
        }
        let key: String, idKey: String, target: String, before: String?
        switch request.action {
        case .moveTab(let id, let destination): key = "tabs"; idKey = "tab_id"; target = id; before = destination
        case .moveWorkspace(let id, let destination): key = "workspaces"; idKey = "workspace_id"; target = id; before = destination
        default: throw HerdrEndpointError.malformed
        }
        let type = key == "tabs" ? "tab_list" : "workspace_list"
        guard object["type"]?.stringValue == type, case .array(let list) = object[key] else { throw HerdrEndpointError.malformed }
        let order = list.compactMap { $0.objectValue?[idKey]?.stringValue }
        var expected = request.capturedOrder.filter { $0 != target }
        expected.insert(target, at: before.flatMap { expected.firstIndex(of: $0) } ?? expected.count)
        guard order == expected else { throw HerdrEndpointError.staleIdentity }
        return order != request.capturedOrder
    }
}
