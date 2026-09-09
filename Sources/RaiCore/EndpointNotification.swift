import Foundation

/// Ephemeral endpoint events remain local to the connected view and never replay after reconnect.
public struct EndpointNotification: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case needsAttention, finished, updateInstalled, custom, error }
    public enum Sound: String, Codable, Sendable { case done, request }
    public enum Position: String, Codable, Sendable { case topLeft, topRight, bottomLeft, bottomRight }
    public let id: UUID
    public let kind: Kind
    public let title: String
    public let body: String?
    public let sound: Sound?
    public let agent: String?
    public let workspaceID: String?
    public let tabID: String?
    public let paneID: String?
    public let position: Position?

    public init(kind: Kind, title: String, body: String? = nil, sound: Sound? = nil,
                agent: String? = nil, workspaceID: String? = nil, tabID: String? = nil,
                paneID: String? = nil, position: Position? = nil) {
        id = UUID(); self.kind = kind; self.title = title; self.body = body; self.sound = sound
        self.agent = agent; self.workspaceID = workspaceID; self.tabID = tabID; self.paneID = paneID; self.position = position
    }

    static func decodeSemantic(_ reader: inout EndpointBinaryReader) throws -> Self {
        let kinds: [Kind] = [.needsAttention, .finished, .updateInstalled, .custom]
        let index = try reader.integer()
        guard index < kinds.count else { throw HerdrEndpointError.malformed }
        let title = try reader.string()
        let body = try reader.optional { try $0.string() }
        let sound: Sound? = try reader.optional {
            switch try $0.integer() {
            case 0: return .done
            case 1: return .request
            default: throw HerdrEndpointError.malformed
            }
        }
        let agent = try reader.optional { try $0.string() }
        let workspace = try reader.optional { try $0.string() }
        let tab = try reader.optional { try $0.string() }
        let pane = try reader.optional { try $0.string() }
        let position: Position? = try reader.optional {
            let positions: [Position] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
            let value = try $0.integer()
            guard value < positions.count else { throw HerdrEndpointError.malformed }
            return positions[Int(value)]
        }
        return .init(kind: kinds[Int(index)], title: title, body: body, sound: sound, agent: agent,
                     workspaceID: workspace, tabID: tab, paneID: pane, position: position)
    }
}
