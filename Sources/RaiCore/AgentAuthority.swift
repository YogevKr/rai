import Foundation

public enum AgentAuthorityAgent: String, CaseIterable, Sendable {
    case pi
    case claude
    case codex
    case gemini
    case cursor
    case devin
    case antigravity = "agy"
    case cline
    case omp
    case mastracode
    case opencode
    case copilot
    case kimi
    case kiro
    case droid
    case amp
    case grok
    case hermes
    case kilo
    case qodercli
    case maki

    public var displayName: String {
        switch self {
        case .pi: "Pi"
        case .claude: "Claude"
        case .codex: "Codex"
        case .gemini: "Gemini"
        case .cursor: "Cursor"
        case .devin: "Devin"
        case .antigravity: "Antigravity"
        case .cline: "Cline"
        case .omp: "OMP"
        case .mastracode: "Mastracode"
        case .opencode: "OpenCode"
        case .copilot: "GitHub Copilot"
        case .kimi: "Kimi"
        case .kiro: "Kiro"
        case .droid: "Droid"
        case .amp: "Amp"
        case .grok: "Grok"
        case .hermes: "Hermes"
        case .kilo: "Kilo"
        case .qodercli: "Qoder CLI"
        case .maki: "Maki"
        }
    }
}

public enum AgentAuthorityState: String, CaseIterable, Sendable {
    case idle
    case working
    case blocked
    case unknown

    public init(status: AgentStatus) {
        switch status {
        case .done, .idle: self = .idle
        case .working: self = .working
        case .blocked: self = .blocked
        case .unknown: self = .unknown
        }
    }

    public var displayName: String {
        rawValue.capitalized
    }
}

public enum AgentAuthorityCLI {
    public static let source = "rai:user"

    public static func reportArguments(
        paneID: String,
        agent: AgentAuthorityAgent,
        state: AgentAuthorityState
    ) -> [String] {
        [
            "pane", "report-agent", paneID,
            "--source", source,
            "--agent", agent.rawValue,
            "--state", state.rawValue,
        ]
    }

    public static func releaseArguments(paneID: String, agent: String) -> [String]? {
        let agent = agent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !agent.isEmpty else { return nil }
        return [
            "pane", "release-agent", paneID,
            "--source", source,
            "--agent", agent,
        ]
    }

    public static func detectionSummary(agent: String?, status: AgentStatus) -> String {
        let agent = agent?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
            .flatMap { raw in
                AgentAuthorityAgent(rawValue: raw)?.displayName ?? raw
            }
            ?? "No agent"
        return "Herdr detects: \(agent) — \(status.rawValue.capitalized)"
    }
}

public struct AgentAuthorityContext: Equatable, Sendable {
    public let paneID: String
    public let agent: String?
    public let status: AgentStatus
    public let sessionSource: String?

    public init(
        paneID: String,
        agent: String?,
        status: AgentStatus,
        sessionSource: String?
    ) {
        self.paneID = paneID
        self.agent = agent
        self.status = status
        self.sessionSource = sessionSource
    }

    public var reportAvailability: AgentAuthorityReportAvailability {
        if let sessionSource, sessionSource != AgentAuthorityCLI.source {
            return .ownedSession(source: sessionSource)
        }
        return .available
    }
}

public enum AgentAuthorityReportAvailability: Equatable, Sendable {
    case available
    case ownedSession(source: String)
}

public enum AgentAuthorityContextParser {
    public static func parse(_ output: String) -> AgentAuthorityContext? {
        guard let data = output.data(using: .utf8),
              let response = try? JSONDecoder().decode(Response.self, from: data) else {
            return nil
        }
        return AgentAuthorityContext(
            paneID: response.result.pane.paneID,
            agent: response.result.pane.agent,
            status: response.result.pane.agentStatus,
            sessionSource: response.result.pane.agentSession?.source
        )
    }

    private struct Response: Decodable {
        let result: Result
    }

    private struct Result: Decodable {
        let pane: Pane
    }

    private struct Pane: Decodable {
        let paneID: String
        let agent: String?
        let agentStatus: AgentStatus
        let agentSession: AgentSession?

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case agent
            case agentStatus = "agent_status"
            case agentSession = "agent_session"
        }
    }

    private struct AgentSession: Decodable {
        let source: String
    }
}

public enum AgentAuthorityRPCError: LocalizedError {
    case invalidResponse
    case remote(code: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Herdr returned an invalid authority response"
        case .remote(let code, let message):
            "\(code): \(message)"
        }
    }
}

public enum AgentAuthorityRPC {
    public static func clearOverride(
        socketPath: String,
        paneID: String
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try clearOverrideBlocking(socketPath: socketPath, paneID: paneID)
        }.value
    }

    static func clearRequestData(
        id: String,
        paneID: String
    ) throws -> Data {
        try JSONEncoder().encode(
            Request(
                id: id,
                method: "pane.clear_agent_authority",
                params: Params(paneID: paneID, source: AgentAuthorityCLI.source)
            )
        )
    }

    static func validateResponse(_ data: Data, id: String) throws {
        let envelope = try JSONDecoder().decode(Response.self, from: data)
        guard envelope.id == id else {
            throw AgentAuthorityRPCError.invalidResponse
        }
        if let error = envelope.error {
            throw AgentAuthorityRPCError.remote(code: error.code, message: error.message)
        }
        guard envelope.result != nil else {
            throw AgentAuthorityRPCError.invalidResponse
        }
    }

    private static func clearOverrideBlocking(
        socketPath: String,
        paneID: String
    ) throws {
        let id = "rai:clear-agent-authority:\(UUID().uuidString)"
        let socket = try UnixSocket(path: socketPath)
        defer { socket.close() }
        try socket.writeLine(clearRequestData(id: id, paneID: paneID))
        try validateResponse(socket.readLine(), id: id)
    }

    private struct Request: Encodable {
        let id: String
        let method: String
        let params: Params
    }

    private struct Params: Encodable {
        let paneID: String
        let source: String

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case source
        }
    }

    private struct Response: Decodable {
        let id: String?
        let result: JSONValue?
        let error: ErrorBody?
    }

    private struct ErrorBody: Decodable {
        let code: String
        let message: String
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
