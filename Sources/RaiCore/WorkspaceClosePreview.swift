import Foundation

public struct WorkspaceClosePreview: Identifiable, Codable, Equatable, Sendable {
    public let workspaceID: String
    public let closeGroup: Bool
    public let connectionID: String?
    public let workspaces: [Workspace]
    public var id: String { workspaceID }
    public var workspaceIDs: [String] { workspaces.map(\.workspaceID) }
    public var title: String { closeGroup ? "Close Workspace Group?" : "Close Workspace?" }
    public var message: String {
        "This will stop all processes in: " + workspaces.map(\.label).joined(separator: ", ") + "."
            + (closeGroup ? " Only listed workspaces will close. Changes during closure can leave part of the group open." : "")
    }

    public init?(snapshot: SessionSnapshot, workspaceID: String, closeGroup: Bool, connectionID: String? = nil) {
        self.init(workspaces: snapshot.workspaces, workspaceID: workspaceID, closeGroup: closeGroup, connectionID: connectionID)
    }

    public init?(workspaces: [Workspace], workspaceID: String, closeGroup: Bool, connectionID: String? = nil) {
        guard let workspace = workspaces.first(where: { $0.workspaceID == workspaceID }) else { return nil }
        self.workspaceID = workspaceID
        self.closeGroup = closeGroup
        self.connectionID = connectionID
        self.workspaces = closeGroup ? Self.group(in: workspaces, workspaceID: workspaceID) : [workspace]
    }

    public func validate(against snapshot: SessionSnapshot, connectionID: String? = nil) throws {
        try validate(against: snapshot.workspaces, supportsGroupClosure: snapshot.protocol >= 22, connectionID: connectionID)
    }

    public func validate(against workspaces: [Workspace], supportsGroupClosure: Bool, connectionID: String? = nil) throws {
        if let connectionID, self.connectionID != connectionID {
            throw HerdrClientError.remote(code: "session_changed", message: "The server connection changed. Review the close action again.")
        }
        guard let current = Self(workspaces: workspaces, workspaceID: workspaceID, closeGroup: closeGroup),
              Set(current.workspaceIDs) == Set(workspaceIDs),
              Set(workspaceIDs).count == workspaceIDs.count else {
            throw HerdrClientError.remote(code: "workspace_changed", message: "The workspace list changed. Review the close action again.")
        }
        if closeGroup, !supportsGroupClosure {
            throw HerdrClientError.remote(code: "unsupported_action", message: "Group closure requires Herdr 0.9 or later.")
        }
        _ = try closureOrder()
        if !closeGroup, Self.group(in: workspaces, workspaceID: workspaceID).count > 1 {
            throw HerdrClientError.remote(code: "workspace_group_close_required", message: "Use Close Group to review all affected workspaces.")
        }
        if !supportsGroupClosure, let worktree = current.workspaces.first?.worktree,
           !worktree.isLinkedWorktree, worktree.repoKey?.isEmpty != false {
            throw HerdrClientError.remote(code: "unsupported_action", message: "Herdr did not provide group identity. Update Herdr before closing this primary workspace.")
        }
    }

    /// Herdr cannot condition a group close on preview membership. Close linked
    /// members individually, then the primary. Every request uses close_group=false,
    /// so the server rejects a primary closure if another client adds a member.
    public func closureOrder() throws -> [String] {
        guard closeGroup, workspaces.count > 1 else { return workspaceIDs }
        let primary = workspaces.filter { $0.worktree?.isLinkedWorktree != true }
        guard primary.count == 1, primary[0].workspaceID == workspaceID else {
            throw HerdrClientError.remote(code: "unsupported_group_layout", message: "This group has multiple primary workspaces. Close linked workspaces individually first.")
        }
        return workspaces.filter { $0.workspaceID != workspaceID }.map(\.workspaceID) + [workspaceID]
    }

    /// Match Herdr's group closure rule: only a primary checkout closes its group.
    public static func group(in snapshot: SessionSnapshot, workspaceID: String) -> [Workspace] {
        group(in: snapshot.workspaces, workspaceID: workspaceID)
    }

    public static func group(in workspaces: [Workspace], workspaceID: String) -> [Workspace] {
        guard let workspace = workspaces.first(where: { $0.workspaceID == workspaceID }) else { return [] }
        guard let worktree = workspace.worktree, !worktree.isLinkedWorktree,
              let key = worktree.repoKey, !key.isEmpty else { return [workspace] }
        return workspaces.filter { $0.worktree?.repoKey == key }
    }
}


extension HerdrEndpointConnection {
    /// Keep the reviewed server socket for every write. Never reconnect a closure.
    public func closeReviewedWorkspaces(_ preview: WorkspaceClosePreview) async throws -> Int {
        guard let initial = snapshot else { throw HerdrEndpointError.staleIdentity }
        guard let captured = WorkspaceClosePreview(workspaces: preview.workspaces, workspaceID: preview.workspaceID,
                                                   closeGroup: preview.closeGroup, connectionID: initial.bootID) else {
            throw HerdrEndpointError.staleIdentity
        }
        let request = try EndpointLayoutRequest(snapshot: initial, owningViewID: UUID(), action: .closeWorkspace(captured))
        var closed: [String] = []
        _ = try await self.request(method: "client_shell.surface.set", params: ["active": .bool(true)], expectedBootID: initial.bootID)
        do {
            for id in try captured.closureOrder() {
                try Task.checkCancellation()
                guard let current = snapshot else { throw HerdrEndpointError.staleIdentity }
                try request.validateClosureProgress(in: current, closed: closed)
                let value = try await self.request(method: "workspace.close",
                    params: ["workspace_id": .string(id), "close_group": .bool(false)], expectedBootID: initial.bootID)
                guard value.objectValue?["type"]?.stringValue == "ok" else { throw HerdrEndpointError.malformed }
                closed.append(id)
            }
        } catch {
            _ = try? await self.request(method: "client_shell.surface.set", params: ["active": .bool(false)], expectedBootID: initial.bootID)
            throw HerdrClientError.remote(code: "workspace_close_incomplete",
                message: "Closed \(closed.count) reviewed workspaces. The last request may have completed. Inspect the remaining workspaces. \(error.localizedDescription)")
        }
        _ = try? await self.request(method: "client_shell.surface.set", params: ["active": .bool(false)], expectedBootID: initial.bootID)
        return closed.count
    }
}
