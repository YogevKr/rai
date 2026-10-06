import Foundation

public struct RaiPaneRenderTarget: Equatable, Sendable {
    public let slotID: UUID
    public let source: RaiPaneReference
    public let connectionID: String
    public let bootID: String
    public let terminalID: String

    public init(slotID: UUID, source: RaiPaneReference, connectionID: String, bootID: String, terminalID: String) {
        self.slotID = slotID
        self.source = source
        self.connectionID = connectionID
        self.bootID = bootID
        self.terminalID = terminalID
    }
}

public enum RaiPaneResolution: Equatable, Sendable {
    case ready(RaiPaneRenderTarget)
    /// The pane identity matches, but the endpoint has not returned its terminal ID yet.
    case resolving
    case endpointOffline
    case paneMissing
    case paneIdentityChanged
}

public struct RaiEndpointProjection: Equatable, Sendable {
    public let endpoint: MachineEndpoint
    public let connectionID: String
    public let snapshot: HerdrEndpointSnapshot
    /// Terminal identifiers come from the API snapshot. Endpoint snapshots
    /// omit them, so the mixed view keeps the mapping beside the snapshot.
    public let terminalIDs: [String: String]

    public init(
        endpoint: MachineEndpoint,
        connectionID: String,
        snapshot: HerdrEndpointSnapshot,
        terminalIDs: [String: String] = [:]
    ) {
        self.endpoint = endpoint
        self.connectionID = connectionID
        self.snapshot = snapshot
        self.terminalIDs = terminalIDs
    }
}

extension RaiComposition {
    /// Resolve one saved slot against the current Herdr endpoint snapshot.
    /// The result stays endpoint-qualified for later input routing.
    public func resolvePaneSlot(
        id: UUID,
        endpointProjection: RaiEndpointProjection?
    ) throws -> RaiPaneResolution {
        guard let slot = paneSlot(id: id) else { throw RaiCompositionError.missingSlot(id) }
        guard let endpointProjection else { return .endpointOffline }
        guard endpointProjection.endpoint == slot.source.endpoint else {
            return .paneIdentityChanged
        }
        let matches = endpointProjection.snapshot.panes.filter {
            $0.objectValue?["pane_id"]?.stringValue == slot.source.paneID
        }
        guard let pane = matches.first else { return .paneMissing }
        let object = pane.objectValue ?? [:]
        guard object["workspace_id"]?.stringValue == slot.source.workspaceID,
              object["tab_id"]?.stringValue == slot.source.tabID,
              let terminalID = object["terminal_id"]?.stringValue
                ?? endpointProjection.terminalIDs[slot.source.paneID] else {
            return .paneIdentityChanged
        }
        guard !terminalID.isEmpty else { return .resolving }
        return .ready(RaiPaneRenderTarget(
            slotID: slot.id,
            source: slot.source,
            connectionID: endpointProjection.connectionID,
            bootID: endpointProjection.snapshot.bootID,
            terminalID: terminalID
        ))
    }

    public func resolveTab(
        id: UUID,
        endpoints: [MachineEndpoint: RaiEndpointProjection]
    ) throws -> [RaiPaneResolution] {
        guard let tab = tab(id: id) else { throw RaiCompositionError.missingTab(id) }
        return try tab.paneSlots.map { slot in
            try resolvePaneSlot(id: slot.id, endpointProjection: endpoints[slot.source.endpoint])
        }
    }
}
