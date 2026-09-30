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
    func addSpace(_ space: RaiSpace) -> Bool {
        do {
            var next = composition
            try next.addSpace(space)
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

    @discardableResult
    func addPaneSlot(_ slot: RaiPaneSlot, to tabID: UUID) -> Bool {
        do {
            var next = composition
            try next.addPaneSlot(slot, to: tabID)
            composition = next
            error = nil
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func receive(endpoint: MachineEndpoint, connectionID: String, snapshot: HerdrEndpointSnapshot) {
        endpoints[endpoint] = RaiEndpointProjection(
            endpoint: endpoint,
            connectionID: connectionID,
            snapshot: snapshot
        )
        error = nil
    }

    func disconnect(endpoint: MachineEndpoint) {
        endpoints.removeValue(forKey: endpoint)
    }

    func resolutions(for tabID: UUID) throws -> [RaiPaneResolution] {
        try composition.resolveTab(id: tabID, endpoints: endpoints)
    }
}
