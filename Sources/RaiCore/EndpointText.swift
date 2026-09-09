import Foundation

public enum EndpointTextAction: Codable, Equatable, Sendable {
    case history(startRow: UInt32, endRow: UInt32, endColumn: UInt16, revision: UInt64, truncated: Bool)
    case prompt(String)
}

public struct EndpointTextRequest: Codable, Equatable, Sendable, Identifiable {
    public static let maximumTextBytes = 1_000_000
    public let id: UUID
    public let bootID: String
    public let paneID: String
    public let action: EndpointTextAction

    public init(id: UUID = UUID(), bootID: String, paneID: String, action: EndpointTextAction) {
        self.id = id; self.bootID = bootID; self.paneID = paneID; self.action = action
    }

    public static func history(surface: HerdrEndpointSurface, paneID: String) throws -> Self {
        guard let pane = surface.panes.first(where: { $0.paneID == paneID }), pane.innerRect.width > 0 else {
            throw HerdrEndpointError.staleIdentity
        }
        let rows = pane.scroll?.rows ?? UInt64(pane.innerRect.height)
        let maximum = pane.scroll?.maximum ?? 0
        guard rows > 0, rows <= UInt64(UInt32.max), maximum <= UInt64(UInt32.max) - rows else { throw HerdrEndpointError.limitExceeded }
        let total = maximum + rows
        // Keep a single server selection read below the endpoint frame budget.
        // The result reports omitted history. Never join separately read wrapped rows.
        let limit = UInt64(max(1, min(1000, maximumTextBytes / max(1, Int(pane.innerRect.width) * 8))))
        let first = total > limit ? total - limit : 0
        return Self(bootID: surface.bootID, paneID: paneID,
            action: .history(startRow: UInt32(first), endRow: UInt32(total - 1),
                endColumn: pane.innerRect.width - 1, revision: pane.contentRevision, truncated: first > 0))
    }

    public var historyRPC: (method: String, params: [String: JSONValue])? {
        guard case .history(let start, let end, let column, let revision, _) = action else { return nil }
        return ("pane.selection.read", ["pane_id": .string(paneID),
            "anchor": .object(["row": .number(Double(start)), "col": .number(0)]),
            "cursor": .object(["row": .number(Double(end)), "col": .number(Double(column))]),
            "content_revision": .number(Double(revision))])
    }

    /// History captures the latest bounded text for the same pane, not a client-selected range.
    public func refreshedHistory(snapshot: HerdrEndpointSnapshot, surface: HerdrEndpointSurface?) throws -> Self {
        guard case .history = action, snapshot.bootID == bootID, let surface, surface.bootID == bootID,
              snapshot.panes.filter({ $0.objectValue?["pane_id"]?.stringValue == paneID }).count == 1 else {
            throw HerdrEndpointError.staleIdentity
        }
        let fresh = try Self.history(surface: surface, paneID: paneID)
        return Self(id: id, bootID: bootID, paneID: paneID, action: fresh.action)
    }

    public func validate(snapshot: HerdrEndpointSnapshot, surface: HerdrEndpointSurface?) throws {
        guard bootID == snapshot.bootID,
              snapshot.panes.contains(where: { $0.objectValue?["pane_id"]?.stringValue == paneID }) else {
            throw HerdrEndpointError.staleIdentity
        }
        switch action {
        case .prompt(let text):
            guard !text.isEmpty, text.utf8.count <= Self.maximumTextBytes, !text.contains("\0"),
                  snapshot.agents.contains(where: { $0.objectValue?["pane_id"]?.stringValue == paneID }) else {
                throw HerdrEndpointError.malformed
            }
        case .history:
            guard let surface, surface.bootID == bootID,
                  try Self.history(surface: surface, paneID: paneID).action == action else {
                throw HerdrEndpointError.staleIdentity
            }
        }
    }
}

/// Retry only read-only stale-content responses. Every attempt captures a fresh revision and range.
public enum EndpointHistoryReader {
    public static func read(capture: @Sendable () async throws -> EndpointTextRequest,
                            send: @Sendable (EndpointTextRequest) async throws -> JSONValue) async throws -> EndpointTextResult {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let request = try await capture()
            do { return try EndpointTextResult.history(await send(request), request: request) }
            catch HerdrClientError.remote(let code, _) where code == "stale_content" && attempt < 2 {
                // Let the endpoint deliver the surface that follows the changed content.
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        throw HerdrEndpointError.staleIdentity
    }
}

public struct EndpointTextResult: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let text: String?
    public let truncated: Bool
    public let error: String?
    public let outcomeUnknown: Bool

    public init(requestID: UUID, text: String? = nil, truncated: Bool = false, error: String? = nil, outcomeUnknown: Bool = false) {
        self.requestID = requestID; self.text = text; self.truncated = truncated; self.error = error; self.outcomeUnknown = outcomeUnknown
    }

    public static func history(_ value: JSONValue, request: EndpointTextRequest) throws -> Self {
        guard value.objectValue?["type"]?.stringValue == "pane_selection",
              value.objectValue?["pane_id"]?.stringValue == request.paneID,
              let text = value.objectValue?["text"]?.stringValue,
              case .history(_, _, _, _, let truncated) = request.action else { throw HerdrEndpointError.malformed }
        guard text.utf8.count <= EndpointTextRequest.maximumTextBytes else { throw HerdrEndpointError.limitExceeded }
        return Self(requestID: request.id, text: text, truncated: truncated)
    }

    public static func promptFailure(_ error: Error, requestID: UUID) -> Self {
        // Herdr can return agent_prompt_failed or timeout after PTY writes begin.
        // Only documented preflight rejection codes prove that no prompt was sent.
        let rejected: Bool
        if let remote = error as? HerdrClientError, case .remote(let code, _) = remote {
            rejected = ["empty_agent_prompt", "agent_not_found", "agent_target_ambiguous",
                        "agent_blocked", "agent_not_ready"].contains(code)
        } else { rejected = false }
        var message = error.localizedDescription
        if !rejected { message += " Submission may have completed. Check the agent before sending again. Rai will not retry." }
        return Self(requestID: requestID, error: message, outcomeUnknown: !rejected)
    }
}

public struct CapturedTextSearch: Equatable {
    public let ranges: [NSRange]
    public let total: Int

    public init(text: String, query: String, maximumResults: Int = 1000) {
        guard !query.isEmpty else { ranges = []; total = 0; return }
        let source = text as NSString
        var cursor = 0
        var matches: [NSRange] = []
        var count = 0
        while cursor < source.length {
            let match = source.range(of: query, options: [.caseInsensitive], range: NSRange(location: cursor, length: source.length - cursor))
            guard match.location != NSNotFound, match.length > 0 else { break }
            if matches.count < max(0, maximumResults) { matches.append(match) }
            count += 1
            cursor = NSMaxRange(match)
        }
        ranges = matches; total = count
    }
}
