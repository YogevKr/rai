import XCTest
@testable import RaiCore

final class EndpointTextTests: XCTestCase {
    private func surface(revision: UInt64 = 2, maximum: UInt64 = 10, rows: UInt64 = 24) throws -> HerdrEndpointSurface {
        let rect: [String: Any] = ["x": 0, "y": 0, "width": 80, "height": 24]
        let cell: [String: Any] = ["symbol": " ", "foreground": 0, "background": 0, "modifiers": 0, "skip": false]
        let pane: [String: Any] = ["paneID": "w1:p1", "contentRevision": revision, "rect": rect, "innerRect": rect,
            "scroll": ["offset": 0, "maximum": maximum, "rows": rows], "focused": true,
            "mouseReporting": false, "pixelMouse": false, "alternateScreen": false, "pixelWidth": 0, "pixelHeight": 0]
        let object: [String: Any] = ["bootID": "boot", "projectionRevision": 1, "revision": 1,
            "grid": ["width": 80, "height": 24, "cells": Array(repeating: cell, count: 1920), "hyperlinks": []],
            "panes": [pane], "splits": [], "graphics": ["assets": [], "placements": [], "retained": []]]
        return try JSONDecoder().decode(HerdrEndpointSurface.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func snapshot(agent: Bool = true, boot: String = "boot") throws -> HerdrEndpointSnapshot {
        let pane: [String: Any] = ["pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1"]
        let object: [String: Any] = ["boot_id": boot, "revision": 1, "panes": [pane], "agents": agent ? [pane] : []]
        return try JSONDecoder().decode(HerdrEndpointSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testHistoryUsesRevisionBoundSelectionWithoutScrollingThePane() throws {
        let surface = try surface()
        let request = try EndpointTextRequest.history(surface: surface, paneID: "w1:p1")
        XCTAssertEqual(request.action, .history(startRow: 0, endRow: 33, endColumn: 79, revision: 2, truncated: false))
        XCTAssertEqual(request.historyRPC?.method, "pane.selection.read")
        XCTAssertEqual(request.historyRPC?.params["content_revision"], .number(2))
        try request.validate(snapshot: snapshot(), surface: surface)
        XCTAssertThrowsError(try request.validate(snapshot: snapshot(), surface: self.surface(revision: 4)))
        XCTAssertThrowsError(try request.validate(snapshot: snapshot(boot: "replacement"), surface: surface))
    }

    func testHostRefreshesHistoryWithoutChangingPaneOrResultIdentity() throws {
        let original = try EndpointTextRequest.history(surface: surface(revision: 2), paneID: "w1:p1")
        let refreshed = try original.refreshedHistory(snapshot: snapshot(), surface: surface(revision: 8, maximum: 20))
        XCTAssertEqual(refreshed.id, original.id)
        XCTAssertEqual(refreshed.paneID, original.paneID)
        XCTAssertEqual(refreshed.action, .history(startRow: 0, endRow: 43, endColumn: 79, revision: 8, truncated: false))
        XCTAssertThrowsError(try original.refreshedHistory(snapshot: snapshot(boot: "other"), surface: surface()))
        let prompt = EndpointTextRequest(bootID: "boot", paneID: "w1:p1", action: .prompt("hello"))
        XCTAssertThrowsError(try prompt.refreshedHistory(snapshot: snapshot(), surface: surface()))
    }

    func testHistoryRetriesOnlyStaleContentAndStopsAfterThreeAttempts() async throws {
        let request = try EndpointTextRequest.history(surface: surface(), paneID: "w1:p1")
        let fixture = HistoryReadFixture(request: request, failures: 1)
        let result = try await EndpointHistoryReader.read(capture: { await fixture.capture() }, send: { try await fixture.send($0) })
        XCTAssertEqual(result.requestID, request.id)
        XCTAssertEqual(result.text, "stable captured text")
        let revisions = await fixture.revisions
        XCTAssertEqual(revisions, [2, 4])
        for (code, count) in [("stale_content", 3), ("pane_not_found", 1)] {
            let failure = HistoryReadFixture(request: request, failures: 9, code: code)
            do {
                _ = try await EndpointHistoryReader.read(capture: { await failure.capture() }, send: { try await failure.send($0) })
                XCTFail("The read must fail after its bounded attempts")
            } catch {}
            let sent = await failure.revisions.count
            XCTAssertEqual(sent, count)
        }
    }

    func testLargeHistoryReportsOmittedRowsAndCannotOverflow() throws {
        let request = try EndpointTextRequest.history(surface: surface(maximum: 10_000), paneID: "w1:p1")
        XCTAssertEqual(request.action, .history(startRow: 9024, endRow: 10023, endColumn: 79, revision: 2, truncated: true))
        XCTAssertThrowsError(try EndpointTextRequest.history(surface: surface(rows: .max), paneID: "w1:p1"))
        XCTAssertThrowsError(try EndpointTextRequest.history(surface: surface(maximum: .max), paneID: "w1:p1"))
    }

    func testHistoryResultPreservesExactUnicodeWhitespaceAndRejectsOversize() throws {
        let request = try EndpointTextRequest.history(surface: surface(), paneID: "w1:p1")
        let text = "  👩🏽‍💻 e\u{301}\n\ntrailing  \n"
        let value: JSONValue = .object(["type": .string("pane_selection"), "pane_id": .string("w1:p1"), "text": .string(text)])
        let result = try EndpointTextResult.history(value, request: request)
        XCTAssertEqual(result.text, text)
        XCTAssertEqual(try JSONDecoder().decode(EndpointTextResult.self, from: JSONEncoder().encode(result)), result)
        let large: JSONValue = .object(["type": .string("pane_selection"), "pane_id": .string("w1:p1"),
            "text": .string(String(repeating: "x", count: EndpointTextRequest.maximumTextBytes + 1))])
        XCTAssertThrowsError(try EndpointTextResult.history(large, request: request))
    }

    func testPromptRequiresAnAgentAndRetainsAllLines() throws {
        let request = EndpointTextRequest(bootID: "boot", paneID: "w1:p1", action: .prompt("first\nsecond\n"))
        try request.validate(snapshot: snapshot(), surface: nil)
        XCTAssertThrowsError(try request.validate(snapshot: snapshot(agent: false), surface: nil))
        XCTAssertThrowsError(try request.validate(snapshot: snapshot(boot: "replacement"), surface: nil))
        for text in ["", "bad\0input"] {
            XCTAssertThrowsError(try EndpointTextRequest(bootID: "boot", paneID: "w1:p1", action: .prompt(text)).validate(snapshot: snapshot(), surface: nil))
        }
        let operation = EndpointBridgeOperation.terminalAction(request)
        XCTAssertEqual(try JSONDecoder().decode(EndpointBridgeOperation.self, from: JSONEncoder().encode(operation)), operation)
    }

    func testSearchUsesUnicodeRangesAndBoundsStoredMatches() {
        let text = "👩🏽‍💻 Alpha\nalpha\nALPHA"
        let search = CapturedTextSearch(text: text, query: "alpha", maximumResults: 2)
        XCTAssertEqual(search.total, 3)
        XCTAssertEqual(search.ranges.count, 2)
        XCTAssertEqual((text as NSString).substring(with: search.ranges[0]), "Alpha")
        XCTAssertEqual((text as NSString).substring(with: search.ranges[1]), "alpha")
        XCTAssertEqual(CapturedTextSearch(text: text, query: "").total, 0)
        XCTAssertEqual(CapturedTextSearch(text: "aaaa", query: "aa").total, 2)
    }

    func testPromptWriteFailureRemainsUncertainAcrossThePhoneBridge() throws {
        let id = UUID()
        for error in [HerdrClientError.remote(code: "agent_prompt_failed", message: "pty actor closed"),
                      .remote(code: "timeout", message: "PTY submission timed out"),
                      .remote(code: "new_unknown_error", message: "unknown phase"), .disconnected] {
            let result = EndpointTextResult.promptFailure(error, requestID: id)
            XCTAssertEqual(result.requestID, id)
            XCTAssertTrue(result.outcomeUnknown)
            XCTAssertTrue(result.error?.contains("Check the agent before sending again.") == true)
            let received = try JSONDecoder().decode(EndpointTextResult.self, from: JSONEncoder().encode(result))
            XCTAssertEqual(received, result)
        }
    }

    func testPromptPreflightRejectionsPermitDraftCorrection() {
        for code in ["empty_agent_prompt", "agent_not_found", "agent_target_ambiguous", "agent_blocked", "agent_not_ready"] {
            let error = HerdrClientError.remote(code: code, message: "No input was sent")
            let result = EndpointTextResult.promptFailure(error, requestID: UUID())
            XCTAssertFalse(result.outcomeUnknown)
            XCTAssertEqual(result.error, error.localizedDescription)
        }
    }
}

private actor HistoryReadFixture {
    let request: EndpointTextRequest
    var failures: Int
    let code: String
    private var captures: UInt64 = 0
    var revisions: [UInt64] = []
    init(request: EndpointTextRequest, failures: Int, code: String = "stale_content") {
        self.request = request; self.failures = failures; self.code = code
    }
    func capture() -> EndpointTextRequest {
        captures += 1
        return EndpointTextRequest(id: request.id, bootID: request.bootID, paneID: request.paneID,
            action: .history(startRow: 0, endRow: 23, endColumn: 79, revision: captures * 2, truncated: false))
    }
    func send(_ request: EndpointTextRequest) throws -> JSONValue {
        if case .history(_, _, _, let revision, _) = request.action { revisions.append(revision) }
        if failures > 0 { failures -= 1; throw HerdrClientError.remote(code: code, message: "fixture rejection") }
        return .object(["type": .string("pane_selection"), "pane_id": .string(request.paneID), "text": .string("stable captured text")])
    }
}
