import Combine
import Foundation
import RaiCore

/// Owns Rai presentation state while Herdr owns every source resource.
@MainActor
final class RaiMixedViewModel: ObservableObject {
    @Published private(set) var composition: RaiComposition
    @Published private(set) var endpoints: [MachineEndpoint: RaiEndpointProjection] = [:]
    @Published private(set) var error: String?

    let store: RaiCompositionStore

    init(
        composition: RaiComposition = RaiComposition(),
        store: RaiCompositionStore = RaiCompositionStore()
    ) {
        self.composition = composition
        self.store = store
    }

    @discardableResult
    func load() -> Bool {
        do {
            if let saved = try store.load() { composition = saved }
            error = nil
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func save() -> Bool {
        do {
            try store.save(composition)
            error = nil
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func replace(_ next: RaiComposition) -> Bool {
        do {
            try next.validate()
            composition = next
            error = nil
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func addTab(_ tab: RaiTab, to spaceID: UUID) -> Bool {
        do {
            var next = composition
            try next.addTab(tab, to: spaceID)
            composition = next
            error = nil
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func newTab(after selectedTabID: UUID?) -> UUID? {
        let space = composition.spaces.first { space in
            space.tabs.contains { $0.id == selectedTabID }
        } ?? composition.spaces.first
        guard let space else { return nil }
        let tab = RaiTab(label: "Rai Tab \(space.tabs.count + 1)")
        return addTab(tab, to: space.id) ? tab.id : nil
    }

    /// Live source tabs do not edit the saved mixed composition. Reuse slot IDs
    /// across metadata revisions so SwiftUI keeps the same terminal clients.
    func showSourceTab(_ tab: InstanceTab, spaceLabel: String) -> UUID? {
        var nextComposition = composition
        let spaceIndex = nextComposition.spaces.firstIndex { $0.source == tab.workspace }
        let existingSpace = spaceIndex.map { nextComposition.spaces[$0] }
        let previous = existingSpace?.tabs.first { existing in
            existing.paneSlots.contains { $0.source.tabID == tab.id }
        }
        let slots = tab.panes.map { source in
            previous?.paneSlots.first { $0.source == source } ?? RaiPaneSlot(source: source)
        }
        let nextTab = RaiTab(id: previous?.id ?? UUID(), label: tab.label, paneSlots: slots)
        if let spaceIndex {
            var space = nextComposition.spaces[spaceIndex]
            space.label = spaceLabel
            if let tabIndex = space.tabs.firstIndex(where: { $0.id == nextTab.id }) {
                space.tabs[tabIndex] = nextTab
            } else {
                space.tabs.append(nextTab)
            }
            nextComposition.spaces[spaceIndex] = space
        } else {
            nextComposition.spaces.append(
                RaiSpace(label: spaceLabel, source: tab.workspace, tabs: [nextTab])
            )
        }
        do {
            try nextComposition.validate()
        } catch {
            self.error = error.localizedDescription
            return nil
        }
        composition = nextComposition
        return nextTab.id
    }

    func receive(
        endpoint: MachineEndpoint,
        connectionID: String,
        snapshot: HerdrEndpointSnapshot,
        terminalIDs: [String: String] = [:]
    ) {
        endpoints[endpoint] = RaiEndpointProjection(
            endpoint: endpoint,
            connectionID: connectionID,
            snapshot: snapshot,
            terminalIDs: terminalIDs
        )
        error = nil
    }

    func disconnect(endpoint: MachineEndpoint) {
        endpoints.removeValue(forKey: endpoint)
    }

    /// Removes a remote workspace from Rai while leaving Herdr's workspace and
    /// every process in it running on the source instance.
    @discardableResult
    func removeSourceWorkspace(_ reference: RaiWorkspaceReference) -> Bool {
        var next = composition
        let oldCount = next.spaces.count
        next.spaces.removeAll { $0.source == reference }
        guard next.spaces.count != oldCount else { return false }
        guard replace(next) else { return false }
        return save()
    }

    /// Removes one remote tab from Rai while leaving its Herdr tab running.
    @discardableResult
    func removeSourceTab(_ reference: RaiWorkspaceReference, tabID: String) -> Bool {
        var next = composition
        guard let spaceIndex = next.spaces.firstIndex(where: { $0.source == reference }) else {
            return false
        }
        let oldTabs = next.spaces[spaceIndex].tabs
        next.spaces[spaceIndex].tabs.removeAll { tab in
            tab.paneSlots.contains { $0.source.tabID == tabID }
        }
        guard next.spaces[spaceIndex].tabs.count != oldTabs.count else { return false }
        if next.spaces[spaceIndex].tabs.isEmpty {
            next.spaces.remove(at: spaceIndex)
        }
        guard replace(next) else { return false }
        return save()
    }

    func resolutions(for tabID: UUID) throws -> [RaiPaneResolution] {
        try composition.resolveTab(id: tabID, endpoints: endpoints)
    }
}
