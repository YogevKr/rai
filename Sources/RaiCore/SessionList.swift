import Foundation

public struct HerdrSession: Codable, Identifiable, Sendable, Equatable {
    public let name: String
    public let isDefault: Bool
    public let isRunning: Bool
    public let sessionDirectory: String
    public let socketPath: String

    public var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case isDefault = "default"
        case isRunning = "running"
        case sessionDirectory = "session_dir"
        case socketPath = "socket_path"
    }
}

public enum SessionListParser {
    public static func parse(_ json: String) throws -> [HerdrSession] {
        try JSONDecoder().decode(Envelope.self, from: Data(json.utf8)).sessions
    }

    private struct Envelope: Decodable {
        let sessions: [HerdrSession]
    }
}
