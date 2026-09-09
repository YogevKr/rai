import Foundation
import XCTest
@testable import RaiCore

private extension XCTestCase {
    func withServer(
        mode: String,
        run: (HerdrClient, URL) async throws -> Void
    ) async throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("rai-scroll-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let socket = root.appendingPathComponent("test.sock")
        let record = root.appendingPathComponent("requests.jsonl")
        let script = try XCTUnwrap(Bundle.module.url(forResource: "fake_herdr_server", withExtension: "py", subdirectory: "Fixtures"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, socket.path, mode, record.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let stopped = expectation(description: "fixture process stopped")
        process.terminationHandler = { _ in stopped.fulfill() }
        try process.run()
        let client = HerdrClient(socketPath: socket.path)
        defer {
            client.disconnect()
            if process.isRunning { process.terminate() }
            try? FileManager.default.removeItem(at: root)
        }
        for _ in 0..<300 {
            if FileManager.default.fileExists(atPath: socket.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket.path))
        var failure: Error?
        do { try await run(client, record) }
        catch { failure = error }
        if process.isRunning { process.terminate() }
        await fulfillment(of: [stopped], timeout: 5)
        if let failure { throw failure }
    }
}

final class HerdrScrollTransportTests: XCTestCase {
    func testGraphicsPolicyDeadlineAndCancellationCloseTheOwnedReader() async throws {
        try await withServer(mode: "graphics_stall") { client, record in
            let started = ContinuousClock.now
            do {
                _ = try await client.paneGraphicsEnabled(paneID: "w1:p1", timeout: .milliseconds(100))
                XCTFail("Expected a graphics policy timeout")
            } catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
            XCTAssertLessThan(started.duration(to: .now), .seconds(2))
            let pending = Task { try await client.paneGraphicsEnabled(paneID: "w1:p1", timeout: .seconds(5)) }
            for _ in 0..<100 {
                if (try? String(contentsOf: record).split(separator: "\n").count) == 2 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(try String(contentsOf: record).split(separator: "\n").count, 2)
            let cancelled = ContinuousClock.now
            pending.cancel()
            do { _ = try await pending.value; XCTFail("Expected graphics policy cancellation") } catch {}
            XCTAssertLessThan(cancelled.duration(to: .now), .seconds(2))
            let closed = URL(fileURLWithPath: record.path + ".graphics-closed")
            for _ in 0..<100 {
                if (try? String(contentsOf: closed).split(separator: "\n").count) == 2 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(try String(contentsOf: closed).split(separator: "\n").count, 2)
            _ = try await client.snapshot()
            let requests = try String(contentsOf: record).split(separator: "\n")
            XCTAssertEqual(requests.filter { $0.contains("pane.graphics.info") }.count, 2)
        }
    }

    func testBoundedGraphicsPolicyPreservesCapabilityResponses() async throws {
        for (mode, expected) in [("success", true), ("graphics_disabled", false), ("graphics_cell_size", true)] {
            try await withServer(mode: mode) { client, _ in
                let enabled = try await client.paneGraphicsEnabled(paneID: "w1:p1")
                XCTAssertEqual(enabled, expected)
                _ = try await client.snapshot()
            }
        }
        try await withServer(mode: "graphics_unknown") { client, _ in
            do {
                _ = try await client.paneGraphicsEnabled(paneID: "w1:p1")
                XCTFail("Unsupported graphics policy must remain unknown")
            } catch HerdrClientError.remote(let code, _) { XCTAssertEqual(code, "unknown_method") }
        }
    }

    func testOversizedUnterminatedPromptResponseFailsBeforeDeadlineWithoutReplay() async throws {
        try await withServer(mode: "prompt_oversized") { client, record in
            let started = ContinuousClock.now
            do {
                _ = try await client.agentPrompt(paneID: "w1:p1", text: "one prompt", timeout: .seconds(5))
                XCTFail("Expected an oversized response error")
            } catch UnixSocketError.lineTooLong(let limit) {
                XCTAssertEqual(limit, HerdrEndpointWire.maximumFrameBytes)
            }
            XCTAssertLessThan(started.duration(to: .now), .seconds(3))
            XCTAssertEqual(try String(contentsOf: record).split(separator: "\n").count, 1)
        }
    }

    func testLargeLegacyHistoryDoesNotUseTheSmallPromptResponseLimit() async throws {
        try await withServer(mode: "large_history") { client, _ in
            let history = try await client.readPane(paneID: "w1:p1")
            XCTAssertEqual(history.text.utf8.count, 3 * 1024 * 1024)
            XCTAssertEqual(history.text.first, "h")
            XCTAssertEqual(history.text.last, "h")
            XCTAssertFalse(history.truncated)
        }
    }

    func testMultilineAgentPromptUsesOneAtomicRequestAndNeverReplays() async throws {
        let prompt = "First line\nSecond line 👩🏽‍💻\n\nFinal line"
        for mode in ["success", "drop_reply"] {
            try await withServer(mode: mode) { client, record in
                do {
                    _ = try await client.agentPrompt(paneID: "w1:p1", text: prompt)
                    XCTAssertEqual(mode, "success")
                } catch { XCTAssertEqual(mode, "drop_reply") }
                let requests = try String(contentsOf: record).split(separator: "\n")
                XCTAssertEqual(requests.count, 1)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(requests[0].utf8)) as? [String: Any])
                XCTAssertEqual(json["method"] as? String, "agent.prompt")
                let params = try XCTUnwrap(json["params"] as? [String: String])
                XCTAssertEqual(params, ["target": "w1:p1", "text": prompt])
            }
        }
    }

    func testStalledAgentPromptHasDeadlineWithoutReplay() async throws {
        try await withServer(mode: "prompt_stall") { client, record in
            let start = ContinuousClock.now
            do {
                _ = try await client.agentPrompt(paneID: "w1:p1", text: "one\ntwo", timeout: .milliseconds(100))
                XCTFail("Expected timeout")
            } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
            XCTAssertLessThan(start.duration(to: .now), .seconds(2))
            XCTAssertEqual(try String(contentsOf: record).split(separator: "\n").count, 1)
        }
    }

    func testPluginDeadlineAndCancellationCloseOnlyTheOwnedRequest() async throws {
        try await withServer(mode: "plugin_stall") { client, record in
            let started = ContinuousClock.now
            do {
                _ = try await client.pluginOperation(.list, timeout: .milliseconds(100))
                XCTFail("Expected a timeout")
            } catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
            XCTAssertLessThan(started.duration(to: .now), .seconds(2))
            let operation = Task { try await client.pluginOperation(.list, timeout: .seconds(5)) }
            for _ in 0..<100 {
                let requests = (try? String(contentsOf: record).split(separator: "\n").count) ?? 0
                if requests >= 2 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            operation.cancel()
            do { _ = try await operation.value; XCTFail("Expected cancellation") } catch {}
            _ = try await client.snapshot()
            let requests = try String(contentsOf: record).split(separator: "\n")
            XCTAssertEqual(requests.filter { $0.contains("plugin.list") }.count, 2)
        }
    }

    func testStalledExplanationHasADeadline() async throws {
        try await withServer(mode: "explanation_stall") { client, _ in
            let started = ContinuousClock.now
            do {
                _ = try await client.explainAgent("w1:p1", timeout: .milliseconds(100))
                XCTFail("Expected a timeout")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("timed out"))
            }
            XCTAssertLessThan(started.duration(to: .now), .seconds(2))
            _ = try await client.snapshot()
        }
    }

    func testStalledExplanationDoesNotBlockSnapshotsAndCanBeCancelled() async throws {
        try await withServer(mode: "explanation_stall") { client, record in
            let explanation = Task { try await client.explainAgent("w1:p1", timeout: .seconds(5)) }
            for _ in 0..<100 {
                if (try? String(contentsOf: record).contains("agent.explain")) == true { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(try String(contentsOf: record).contains("agent.explain"))
            let started = ContinuousClock.now
            _ = try await client.snapshot()
            XCTAssertLessThan(started.duration(to: .now), .seconds(2))
            explanation.cancel()
            do {
                _ = try await explanation.value
                XCTFail("Expected cancellation")
            } catch {}
            XCTAssertLessThan(started.duration(to: .now), .seconds(2))
        }
    }

    func testWorkspaceClosureSendsExplicitGroupIntent() async throws {
        try await withServer(mode: "success") { client, record in
            try await client.closeWorkspace("w1")
            try await client.closeWorkspace("w1", closeGroup: true)
            let requests = try String(contentsOf: record).split(separator: "\n").map {
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
            }
            XCTAssertEqual(requests.count, 2)
            for (request, group) in zip(requests, [false, true]) {
                XCTAssertEqual(request["method"] as? String, "workspace.close")
                let params = try XCTUnwrap(request["params"] as? [String: Any])
                XCTAssertEqual(params["workspace_id"] as? String, "w1")
                XCTAssertEqual(params["close_group"] as? Bool, group)
            }
        }
    }

    func testScrollSendsOneTypedRequestWithoutTerminalInput() async throws {
        try await withServer(mode: "success") { client, record in
            try await client.scrollPane("w1:p1", offsetFromBottom: 123)
            let requests = try String(contentsOf: record).split(separator: "\n")
            XCTAssertEqual(requests.count, 1)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(requests[0].utf8)) as? [String: Any])
            XCTAssertEqual(json["method"] as? String, "pane.scroll")
            let params = try XCTUnwrap(json["params"] as? [String: Any])
            XCTAssertEqual(params["pane_id"] as? String, "w1:p1")
            XCTAssertEqual(params["offset_from_bottom"] as? Int, 123)
        }
    }

    func testLostScrollReplyNeverReplaysTheWrite() async throws {
        try await withServer(mode: "drop_reply") { client, record in
            do {
                try await client.scrollPane("w1:p1", offsetFromBottom: 123)
                XCTFail("A lost response must report failure")
            } catch {}
            XCTAssertEqual(try String(contentsOf: record).split(separator: "\n").count, 1)
        }
    }

    func testLostInputReplyNeverReplaysTextOrKeys() async throws {
        try await withServer(mode: "drop_reply") { client, record in
            for bytes in [Array("prompt".utf8), [UInt8(13)]] {
                do {
                    try await client.sendInput(paneID: "w1:p1", bytes: bytes)
                    XCTFail("A lost input response must report failure")
                } catch {}
            }
            XCTAssertEqual(try String(contentsOf: record).split(separator: "\n").count, 2)
        }
    }

    func testRepeatedScrollActionsUseFreshConnections() async throws {
        try await withServer(mode: "success") { client, record in
            try await client.scrollPane("w1:p1", offsetFromBottom: 123)
            try await client.scrollPane("w1:p1", offsetFromBottom: 0)
            XCTAssertEqual(try String(contentsOf: record).split(separator: "\n").count, 2)
        }
    }

    func testOlderServerReturnsAnErrorWithoutWheelFallback() async throws {
        try await withServer(mode: "unsupported") { client, record in
            do {
                try await client.scrollPane("w1:p1", offsetFromBottom: 123)
                XCTFail("Unsupported direct scrolling must report failure")
            } catch let HerdrClientError.remote(code, _) {
                XCTAssertEqual(code, "invalid_request")
            }
            XCTAssertEqual(try String(contentsOf: record).split(separator: "\n").count, 1)
        }
    }
}

final class HerdrEventTransportTests: XCTestCase {
    func testSnapshotSelectedSubscriptionReceivesClosureWithoutOtherEvents() async throws {
        for version in [1, 13, 14, 19, 22] {
            try await withServer(mode: "events_closed_\(version)") { client, record in
                let initial = client.subscribe()
                defer { initial.close() }
                var initialMessages = initial.messages.makeAsyncIterator()
                guard case .ready = try await initialMessages.next() else { return XCTFail("Missing initial readiness") }
                let snapshot = try await client.snapshot()
                XCTAssertEqual(snapshot.workspaces.map(\.workspaceID), ["w1"])
                XCTAssertEqual(snapshot.panes.map(\.paneID), ["w1:p1"])
                initial.close()

                let filter = HerdrEventFilter(snapshot: snapshot)
                XCTAssertTrue(filter.subscriptions.contains("workspace.closed"))
                let selected = client.subscribe(subscriptions: filter.subscriptions, paneIDs: filter.paneIDs)
                defer { selected.close() }
                var messages = selected.messages.makeAsyncIterator()
                guard case .ready = try await messages.next() else { return XCTFail("Missing selected readiness") }
                let beforeClosure = try await client.snapshot()
                XCTAssertEqual(beforeClosure.workspaces.map(\.workspaceID), ["w1"])
                guard case .event(let event) = try await messages.next() else { return XCTFail("Missing closure event") }
                XCTAssertEqual(event.name, "workspace.closed")
                XCTAssertEqual(event.data["workspace_id"], .string("w1"))
                let refreshed = try await client.snapshot()
                XCTAssertTrue(refreshed.workspaces.isEmpty)
                XCTAssertTrue(refreshed.panes.isEmpty)
                XCTAssertTrue(HerdrEventFilter(snapshot: refreshed).paneIDs.isEmpty)

                let requests = try String(contentsOf: record).split(separator: "\n").map {
                    try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
                }
                let subscriptions = requests.filter { $0["method"] as? String == "events.subscribe" }
                XCTAssertEqual(subscriptions.count, 2)
                let params = try XCTUnwrap(subscriptions.last?["params"] as? [String: Any])
                let types = try XCTUnwrap(params["subscriptions"] as? [[String: Any]]).compactMap { $0["type"] as? String }
                XCTAssertTrue(types.contains("workspace.closed"))
            }
        }
    }

    func testUnknownProtocolRejectsClosureButAcceptsBaseline() async throws {
        try await withServer(mode: "events_closed_0") { client, _ in
            let unsupported = client.subscribe(subscriptions: HerdrClient.defaultSubscriptions + ["workspace.closed"])
            defer { unsupported.close() }
            var rejected = unsupported.messages.makeAsyncIterator()
            do { _ = try await rejected.next(); XCTFail("Unknown event types must reject the subscription.") }
            catch let HerdrClientError.remote(code, _) { XCTAssertEqual(code, "invalid_request") }
            let selected = client.subscribe(subscriptions: HerdrClient.subscriptions(forProtocol: 0))
            defer { selected.close() }
            var messages = selected.messages.makeAsyncIterator()
            guard case .ready = try await messages.next() else { return XCTFail("Missing compatible readiness") }
            let snapshot = try await client.snapshot()
            XCTAssertEqual(snapshot.protocol, 0)
            XCTAssertEqual(snapshot.workspaces.map(\.workspaceID), ["w1"])
        }
    }

    func testSnapshotSelectedSubscriptionReceivesRenameAndRefreshesWithoutPaneChanges() async throws {
        for version in [14, 17, 19, 22] {
            try await withServer(mode: "events_rename_\(version)") { client, record in
                let initial = client.subscribe()
                defer { initial.close() }
                var initialMessages = initial.messages.makeAsyncIterator()
                guard case .ready = try await initialMessages.next() else { return XCTFail("Missing initial readiness") }
                let snapshot = try await client.snapshot()
                XCTAssertEqual(snapshot.workspaces.first?.label, "initial")
                initial.close()

                let filter = HerdrEventFilter(snapshot: snapshot)
                XCTAssertTrue(filter.subscriptions.contains("workspace.renamed"))
                let selected = client.subscribe(subscriptions: filter.subscriptions, paneIDs: filter.paneIDs)
                defer { selected.close() }
                var messages = selected.messages.makeAsyncIterator()
                guard case .ready = try await messages.next() else { return XCTFail("Missing selected readiness") }
                let beforeRename = try await client.snapshot()
                XCTAssertEqual(beforeRename.workspaces.first?.label, "initial")
                guard case .event(let event) = try await messages.next() else { return XCTFail("Missing rename event") }
                XCTAssertEqual(event.name, "workspace.renamed")
                XCTAssertEqual(event.data["workspace_id"], .string("w1"))
                let refreshed = try await client.snapshot()
                XCTAssertEqual(refreshed.workspaces.first?.label, "renamed")
                XCTAssertEqual(refreshed.panes, beforeRename.panes)
                XCTAssertEqual(HerdrEventFilter(snapshot: refreshed), filter)

                let requests = try String(contentsOf: record).split(separator: "\n").map {
                    try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
                }
                let subscriptionRequests = requests.filter { $0["method"] as? String == "events.subscribe" }
                XCTAssertEqual(subscriptionRequests.count, 2)
                let params = try XCTUnwrap(subscriptionRequests.last?["params"] as? [String: Any])
                let types = try XCTUnwrap(params["subscriptions"] as? [[String: Any]]).compactMap { $0["type"] as? String }
                XCTAssertTrue(types.contains("workspace.renamed"))
                XCTAssertEqual(types.contains("workspace.reordered"), version >= 19)
            }
        }
    }

    func testOldProtocolRejectsUnsupportedRenameButAcceptsSelectedBaseline() async throws {
        try await withServer(mode: "events_rename_13") { client, _ in
            let unsupported = client.subscribe(subscriptions: HerdrClient.defaultSubscriptions + ["workspace.renamed"])
            defer { unsupported.close() }
            var rejected = unsupported.messages.makeAsyncIterator()
            do { _ = try await rejected.next(); XCTFail("Unknown event types must reject the subscription.") }
            catch let HerdrClientError.remote(code, _) { XCTAssertEqual(code, "invalid_request") }

            let selected = client.subscribe(subscriptions: HerdrClient.subscriptions(forProtocol: 13))
            defer { selected.close() }
            var messages = selected.messages.makeAsyncIterator()
            guard case .ready = try await messages.next() else { return XCTFail("Missing compatible readiness") }
            let snapshot = try await client.snapshot()
            XCTAssertEqual(snapshot.protocol, 13)
            XCTAssertEqual(snapshot.workspaces.first?.label, "initial")
        }
    }

    func testAcknowledgementPrecedesSnapshotAndBuffersChangesOnBothVersions() async throws {
        for mode in ["events", "events_legacy"] {
            try await withServer(mode: mode) { client, record in
                let subscription = client.subscribe()
                defer { subscription.close() }
                var iterator = subscription.messages.makeAsyncIterator()
                guard case .ready = try await iterator.next() else {
                    return XCTFail("Expected subscription readiness before the snapshot")
                }
                let snapshot = try await client.snapshot()
                XCTAssertEqual(snapshot.panes.map(\.paneID), ["w1:p1"])
                guard case .event(let event) = try await iterator.next() else {
                    return XCTFail("Expected the event buffered during the snapshot read")
                }
                XCTAssertEqual(event.name, "pane.created")
                XCTAssertEqual(event.data["pane_id"]?.stringValue, "w1:p2")
                let refreshed = try await client.snapshot()
                XCTAssertEqual(refreshed.panes.map(\.paneID), ["w1:p1", "w1:p2"])
                XCTAssertNotEqual(HerdrEventFilter(snapshot: snapshot), HerdrEventFilter(snapshot: refreshed))
                let requests = try String(contentsOf: record).split(separator: "\n")
                XCTAssertTrue(requests[0].contains("events.subscribe"))
                XCTAssertTrue(requests[1].contains("session.snapshot"))
            }
        }
    }

    func testReplacedSubscriptionUsesNewPaneFiltersAndFreshSnapshot() async throws {
        try await withServer(mode: "events") { client, record in
            var snapshot: SessionSnapshot?
            for _ in 0..<2 {
                let filter = HerdrEventFilter(snapshot: snapshot)
                let subscription = client.subscribe(subscriptions: filter.subscriptions, paneIDs: filter.paneIDs)
                var iterator = subscription.messages.makeAsyncIterator()
                guard case .ready = try await iterator.next() else { return XCTFail("Missing readiness") }
                _ = try await client.snapshot()
                guard case .event = try await iterator.next() else { return XCTFail("Missing buffered event") }
                snapshot = try await client.snapshot()
                subscription.close()
            }
            XCTAssertEqual(snapshot?.panes.count, 3)
            let requests = try String(contentsOf: record).split(separator: "\n").map {
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
            }
            let subscriptions = requests.filter { $0["method"] as? String == "events.subscribe" }
            XCTAssertEqual(subscriptions.count, 2)
            let params = try XCTUnwrap(subscriptions[1]["params"] as? [String: Any])
            let filters = try XCTUnwrap(params["subscriptions"] as? [[String: Any]])
            XCTAssertEqual(Set(filters.compactMap { $0["pane_id"] as? String }), ["w1:p1", "w1:p2"])
        }
    }

    func testInvalidAcknowledgementAndPrematureEventsFail() async throws {
        for mode in ["events_bad_ack", "events_before_ack"] {
            try await withServer(mode: mode) { client, _ in
                let subscription = client.subscribe()
                defer { subscription.close() }
                var iterator = subscription.messages.makeAsyncIterator()
                do {
                    _ = try await iterator.next()
                    XCTFail("The stream must reject invalid initialization")
                } catch let error as HerdrClientError {
                    guard case .invalidEnvelope = error else { return XCTFail("Wrong error: \(error)") }
                }
            }
        }
    }

    func testClosingAnUnacknowledgedSubscriptionReleasesTheConsumer() async throws {
        try await withServer(mode: "events_no_ack") { client, _ in
            let subscription = client.subscribe()
            let finished = self.expectation(description: "closed stream finishes")
            let consumer = Task {
                for try await _ in subscription.messages { XCTFail("Unexpected message") }
                finished.fulfill()
            }
            subscription.close()
            await self.fulfillment(of: [finished], timeout: 2)
            try await consumer.value
        }
    }
}
