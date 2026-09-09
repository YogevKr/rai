import Foundation

public struct EndpointAgentLaunchRequest: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case claude, codex }
    public let id: UUID
    public let bootID: String
    public let owningViewID: UUID
    public let paneID: String
    public let name: String
    public let kind: Kind
    public init(bootID: String, owningViewID: UUID, paneID: String, name: String, kind: Kind) {
        id = UUID(); self.bootID = bootID; self.owningViewID = owningViewID; self.paneID = paneID; self.name = name; self.kind = kind
    }
    public func validate(in snapshot: HerdrEndpointSnapshot) throws {
        guard snapshot.bootID == bootID,
              snapshot.panes.filter({ $0.objectValue?["pane_id"]?.stringValue == paneID }).count == 1 else {
            throw HerdrEndpointError.staleIdentity
        }
        guard Self.isValidName(name) else { throw HerdrEndpointError.malformed }
    }
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.utf8.first, (97...122).contains(first), name.utf8.count <= 32 else { return false }
        return name.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
    }
    public var params: [String: JSONValue] {
        ["pane_id": .string(paneID), "name": .string(name), "kind": .string(kind.rawValue), "timeout_ms": .number(10_000)]
    }
    public func resultAfterLaunch(_ value: JSONValue, focus: () async throws -> Void) async throws -> EndpointAgentLaunchResult {
        try validateResult(value)
        var message = "Agent started. Review its terminal for login or folder approval."
        do { try await focus() }
        catch {
            message = "Agent started, but its pane could not receive focus. Open that pane before starting another agent."
        }
        try Task.checkCancellation()
        return .init(requestID: id, message: message, succeeded: true)
    }

    public func validateResult(_ value: JSONValue) throws {
        guard value.objectValue?["agent"]?.objectValue?["pane_id"]?.stringValue == paneID else {
            throw HerdrEndpointError.malformed
        }
    }
}

public struct EndpointAgentLaunchResult: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let message: String
    public let succeeded: Bool
    public init(requestID: UUID, message: String, succeeded: Bool) {
        self.requestID = requestID; self.message = message; self.succeeded = succeeded
    }
}
