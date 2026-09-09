import CryptoKit
import Foundation

extension MachineResource {
    public var notificationID: String {
        let values = [endpoint.profileID ?? "local", endpoint.session, bootID, paneID]
        let data = (try? JSONEncoder().encode(values)) ?? Data()
        return "machine-" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public var isValidNotificationTarget: Bool {
        guard (try? MachineOperation.validateSession(endpoint.session)) != nil else { return false }
        if let id = endpoint.profileID, (try? MachineOperation.validateProfile(id)) == nil { return false }
        return [connectionID, bootID, paneID].allSatisfy {
            !$0.isEmpty && $0.utf8.count <= 512 && $0.rangeOfCharacter(from: .controlCharacters) == nil
        }
    }
}

public enum MachineNotificationRoute: Equatable {
    case legacy, invalid, machine(MachineResource)

    public static func decode(_ userInfo: [AnyHashable: Any]) -> Self {
        guard let value = userInfo["machineResource"] else { return .legacy }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let target = try? JSONDecoder().decode(MachineResource.self, from: data),
              target.isValidNotificationTarget else { return .invalid }
        return .machine(target)
    }
}

public struct MachineNotice: Codable, Equatable, Identifiable, Sendable {
    public let resource: MachineResource
    public let machineLabel: String
    public let agentName: String
    public let workspaceID: String
    public let status: AgentStatus
    public let occurredAt: Date
    public var id: String { resource.notificationID }
}

public struct MachineNotificationChanges: Sendable {
    public var notices: [MachineNotice] = []
    public var retiredIDs: [String] = []
}

/// Seed every connection before emitting changes. Reconnect never replays an old blocked state.
public struct MachineNotificationTracker {
    private struct State {
        let bootID: String
        let statuses: [String: AgentStatus]
        let resources: [String: MachineResource]
    }
    private var previous: [MachineEndpoint: State] = [:]
    public init() {}
    @discardableResult
    public mutating func disconnect(_ endpoint: MachineEndpoint) -> MachineNotificationChanges {
        let old = previous.removeValue(forKey: endpoint)
        return .init(retiredIDs: old?.resources.values.map(\.notificationID) ?? [])
    }

    public mutating func receive(_ snapshot: HerdrEndpointSnapshot, entry: MachineEntry, now: Date = Date()) -> MachineNotificationChanges {
        guard let connectionID = entry.connectionID else { return .init() }
        let rows = snapshot.agents.compactMap(\.objectValue)
        var statuses: [String: AgentStatus] = [:]
        var resources: [String: MachineResource] = [:]
        for row in rows {
            guard let pane = row["pane_id"]?.stringValue,
                  let status = row["agent_status"]?.stringValue.flatMap(AgentStatus.init(rawValue:)) else { continue }
            statuses[pane] = status
            resources[pane] = .init(endpoint: entry.endpoint, connectionID: connectionID, bootID: snapshot.bootID, paneID: pane)
        }
        let old = previous.updateValue(.init(bootID: snapshot.bootID, statuses: statuses, resources: resources), forKey: entry.endpoint)
        guard let old else { return .init() }
        guard old.bootID == snapshot.bootID else {
            return .init(retiredIDs: old.resources.values.map(\.notificationID))
        }
        var changes = MachineNotificationChanges()
        for (pane, status) in old.statuses where statuses[pane] != status {
            if let resource = old.resources[pane] { changes.retiredIDs.append(resource.notificationID) }
        }
        for row in rows {
            guard let pane = row["pane_id"]?.stringValue, let status = statuses[pane],
                  status != old.statuses[pane], let resource = resources[pane] else { continue }
            let before = old.statuses[pane]
            let completed = (status == .done && before != nil) || (status == .idle && before == .working)
            guard status == .blocked || completed else { continue }
            changes.notices.append(.init(resource: resource, machineLabel: entry.label,
                agentName: row["name"]?.stringValue ?? row["agent"]?.stringValue ?? pane,
                workspaceID: row["workspace_id"]?.stringValue ?? "", status: completed ? .done : .blocked, occurredAt: now))
        }
        return changes
    }
}
