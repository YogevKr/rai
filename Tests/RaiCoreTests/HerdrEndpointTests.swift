import Foundation
import XCTest
@testable import RaiCore

final class HerdrEndpointTests: XCTestCase {
    func testEveryResizePreservesNegotiatedPixelMouseCapability() async throws {
        try await withFixture("mutation") { endpoint, record in
            _ = try await endpoint.connect(socketPath: record.deletingLastPathComponent().appendingPathComponent("test.sock").path)
            try await endpoint.resize(columns: 80, rows: 24)
            try await endpoint.resize(columns: 99, rows: 44)
            _ = try await endpoint.request(method: "client_shell.surface.set", expectedBootID: "boot")
            let frames = try String(contentsOf: record).split(separator: "\n")
            XCTAssertTrue(frames[0].contains(Data("\"pixel_mouse\":true".utf8).map { String(format: "%02x", $0) }.joined()))
            XCTAssertEqual(Array(frames.filter { $0.hasPrefix("0c") }), ["0c0810501801", "0c0810632c01"])
        }
    }

    func testPopupInputUsesFrozenTargetTagAndRejectsTiledAndRetiredTargets() async throws {
        try await withFixture("popup") { endpoint, record in
            _ = try await endpoint.connect(socketPath: record.deletingLastPathComponent().appendingPathComponent("test.sock").path)
            _ = try await endpoint.request(method: "client_shell.surface.set", expectedBootID: "boot")
            var frames = endpoint.surfaces.makeAsyncIterator()
            let first = try await frames.next()
            XCTAssertEqual(first?.popup?.terminalID, "popup")
            for popupID: String? in [nil, "other-popup"] {
                do {
                    try await endpoint.sendInput(.text("x"), paneID: "phone", bootID: "boot", projectionRevision: 3, popupID: popupID)
                    XCTFail("Expected target rejection")
                } catch { XCTAssertEqual(error as? HerdrEndpointError, .staleIdentity) }
            }
            try await endpoint.sendInput(.text("x"), paneID: "phone", bootID: "boot", projectionRevision: 3, popupID: "popup")
            let retired = try await frames.next()
            XCTAssertNil(retired?.popup)
            do {
                try await endpoint.sendInput(.text("late"), paneID: "phone", bootID: "boot", projectionRevision: 3, popupID: "popup")
                XCTFail("Expected retired popup rejection")
            } catch { XCTAssertEqual(error as? HerdrEndpointError, .staleIdentity) }
            let lines = try String(contentsOf: record).split(separator: "\n")
            XCTAssertEqual(lines.count, 3)
            XCTAssertEqual(lines.last, "0e05706f70757001010178")
        }
    }

    func testWindowTitlesRemainInTheirConnectionAndSupportReset() async throws {
        try await withFixture("window_title") { endpoint, record in
            var titles = endpoint.windowTitles.makeAsyncIterator()
            _ = try await endpoint.connect(socketPath: record.deletingLastPathComponent().appendingPathComponent("test.sock").path)
            _ = try await endpoint.request(method: "client_shell.surface.set", expectedBootID: "boot")
            let title = try await titles.next()
            XCTAssertEqual(title ?? nil, "Rai scoped title")
            try await endpoint.sendInput(.text("x"), paneID: "phone", bootID: "boot", projectionRevision: 3)
            let reset = try await titles.next()
            guard case .some(.none) = reset else { return XCTFail("Expected an explicit title reset") }
            endpoint.disconnect()
            do {
                _ = try await titles.next()
                _ = try await titles.next()
            } catch { XCTAssertTrue(error is HerdrClientError) }
        }
    }

    func testSemanticKeysKeepModeSelectionOnTheServer() {
        var up = Data()
        EndpointInput.key(EndpointKey(code: .special(.up))).encode(to: &up)
        XCTAssertEqual(up, Data([0, 4, 0, 0, 1, 0, 0, 0, 0, 0]))
        var control = Data()
        EndpointInput.key(EndpointKey(code: .character("c"), modifiers: 2, isRepeat: true)).encode(to: &control)
        XCTAssertEqual(control, Data([0, 15, 99, 2, 1, 1, 0, 0, 0, 0, 0]))
        var unicode = Data()
        EndpointInput.key(EndpointKey(code: .character("א"), modifiers: 2)).encode(to: &unicode)
        XCTAssertEqual(unicode, Data([0, 15, 0xd7, 0x90, 2, 0, 1, 0, 0, 0, 0, 0]))
    }

    func testFrozenControlWireAndIntegerBoundaries() throws {
        // Frozen generation-one discriminant followed by two bincode strings.
        let golden = Data([20, 1, 107, 2, 123, 125])
        XCTAssertEqual(HerdrEndpointWire.control(kind: "k", data: "{}"), golden)
        XCTAssertEqual(try HerdrEndpointWire.decode(golden), .control(kind: "k", data: "{}"))
        let encoded = Data([250, 251, 251, 0, 251, 255, 255, 252, 0, 0, 1, 0,
                            253, 255, 255, 255, 255, 255, 255, 255, 255])
        var reader = EndpointBinaryReader(data: encoded)
        for expected: UInt64 in [250, 251, 65535, 65536, UInt64.max] {
            XCTAssertEqual(try reader.integer(), expected)
        }
        XCTAssertTrue(reader.isAtEnd)
    }

    func testMalformedMessagesCannotOverreadOrAllocateFromAClaimedLength() {
        let malformed: [Data] = [Data(), Data([20]), Data([20, 253] + Array(repeating: 255, count: 8)),
                                 Data([20, 1, 255, 0]), Data([20, 0, 0, 1]), Data([18, 0, 0, 2, 0])]
        for bytes in malformed { XCTAssertThrowsError(try HerdrEndpointWire.decode(bytes)) }
        XCTAssertThrowsError(try HerdrEndpointWire.decode(Data(repeating: 0, count: 2 * 1024 * 1024 + 1)))
    }

    func testSnapshotKeepsFullWidthRevisionAndFutureFields() throws {
        let json = #"{"boot_id":"boot","revision":18446744073709551615,"future":{"kind":"new"}}"#
        let snapshot = try JSONDecoder().decode(HerdrEndpointSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.revision, UInt64.max)
        XCTAssertTrue(snapshot.commands.isEmpty)
    }

    func testFragmentedHandshakeIgnoresOldSnapshotsAndAssemblesResponseChunks() async throws {
        try await withFixture("success") { endpoint, record in
            let first = try await endpoint.connect(socketPath: record.deletingLastPathComponent().appendingPathComponent("test.sock").path)
            XCTAssertEqual(first.bootID, "boot")
            let result = try await endpoint.request(method: "client_shell.surface.set", params: ["active": .bool(false)], expectedBootID: first.bootID)
            XCTAssertEqual(result.objectValue?["active"], .bool(false))
            let snapshot = await endpoint.snapshot
            XCTAssertEqual(snapshot?.focusedPaneID, "phone")
            XCTAssertEqual(snapshot?.revision, 3)
            let welcome = await endpoint.welcome
            XCTAssertEqual(welcome?.capabilities, [])
            let lines = try String(contentsOf: record).split(separator: "\n")
            XCTAssertEqual(lines.count, 2, "One hello and one request; no replay")
        }
    }

    func testRejectsStaleAndUnsupportedRequestsBeforeWriting() async throws {
        try await withFixture("success") { endpoint, record in
            _ = try await endpoint.connect(socketPath: record.deletingLastPathComponent().appendingPathComponent("test.sock").path)
            do {
                _ = try await endpoint.request(method: "client_shell.surface.set", expectedBootID: "old")
                XCTFail("Expected stale identity rejection")
            } catch { XCTAssertEqual(error as? HerdrEndpointError, .staleIdentity) }
            do {
                _ = try await endpoint.request(method: "unsupported", expectedBootID: "boot")
                XCTFail("Expected capability rejection")
            } catch { XCTAssertTrue(error.localizedDescription.contains("Unsupported method")) }
            XCTAssertEqual(try String(contentsOf: record).split(separator: "\n").count, 1)
        }
    }

    func testHandshakeDeadlineAndFrameLimit() async throws {
        for mode in ["startup_stall", "oversized", "bad_codec"] {
            try await withFixture(mode) { endpoint, record in
                do {
                    _ = try await endpoint.connect(socketPath: record.deletingLastPathComponent().appendingPathComponent("test.sock").path, timeout: .milliseconds(200))
                    XCTFail("Expected handshake rejection: \(mode)")
                } catch {
                    XCTAssertNotNil(error as? HerdrEndpointError)
                }
            }
        }
    }

    func testRequestDeadlineNeverReplaysTheWrite() async throws {
        try await withFixture("request_stall") { endpoint, record in
            _ = try await endpoint.connect(socketPath: record.deletingLastPathComponent().appendingPathComponent("test.sock").path)
            do {
                _ = try await endpoint.request(method: "client_shell.surface.set", expectedBootID: "boot", timeout: .milliseconds(100))
                XCTFail("Expected request timeout")
            } catch { XCTAssertEqual(error as? HerdrEndpointError, .timedOut) }
            XCTAssertEqual(try String(contentsOf: record).split(separator: "\n").count, 2)
        }
    }

    func testDeadlineClosesASocketWhosePeerDoesNotReadTheRequest() async throws {
        try await withFixture("write_stall") { endpoint, record in
            _ = try await endpoint.connect(socketPath: record.deletingLastPathComponent().appendingPathComponent("test.sock").path)
            let began = ContinuousClock.now
            do {
                _ = try await endpoint.request(method: "client_shell.surface.set", params: ["payload": .string(String(repeating: "x", count: 1_500_000))], expectedBootID: "boot", timeout: .milliseconds(100))
                XCTFail("Expected timeout while writing")
            } catch { XCTAssertEqual(error as? HerdrEndpointError, .timedOut) }
            XCTAssertLessThan(began.duration(to: .now), .seconds(2))
        }
    }

    func testConnectionFailureClosesBothUpdateStreams() async {
        let endpoint = HerdrEndpointConnection()
        let metadataClosed = expectation(description: "metadata stream closed")
        let surfaceClosed = expectation(description: "surface stream closed")
        let metadata = Task {
            do { for try await _ in endpoint.snapshots {} } catch {}
            metadataClosed.fulfill()
        }
        let surfaces = Task {
            do { for try await _ in endpoint.surfaces {} } catch {}
            surfaceClosed.fulfill()
        }
        defer { metadata.cancel(); surfaces.cancel(); endpoint.disconnect() }
        do {
            _ = try await endpoint.connect(socketPath: "/tmp/rai-missing-\(UUID().uuidString).sock")
            XCTFail("Expected missing socket failure")
        } catch {}
        await fulfillment(of: [metadataClosed, surfaceClosed], timeout: 1)
    }

    func testInputDeadlineClosesASocketWithoutAPendingRequest() async throws {
        try await withFixture("input_stall") { endpoint, record in
            _ = try await endpoint.connect(socketPath: record.deletingLastPathComponent().appendingPathComponent("test.sock").path)
            _ = try await endpoint.request(method: "client_shell.surface.set", expectedBootID: "boot")
            var frames = endpoint.surfaces.makeAsyncIterator()
            _ = try await frames.next()
            let began = ContinuousClock.now
            do {
                try await endpoint.sendText(String(repeating: "x", count: 1_500_000), paneID: "phone", bootID: "boot", projectionRevision: 3, timeout: .milliseconds(100))
                XCTFail("Expected input write timeout")
            } catch { XCTAssertEqual(error as? HerdrEndpointError, .timedOut) }
            XCTAssertLessThan(began.duration(to: .now), .seconds(2))
            do {
                try await endpoint.resize(columns: 80, rows: 24)
                XCTFail("A timed-out connection must reject later input")
            } catch { XCTAssertEqual(error as? HerdrEndpointError, .timedOut) }
        }
    }

    func testMultilinePasteUsesOneSemanticPasteEvent() async throws {
        try await withFixture("paste") { endpoint, record in
            _ = try await endpoint.connect(socketPath: record.deletingLastPathComponent().appendingPathComponent("test.sock").path)
            _ = try await endpoint.request(method: "client_shell.surface.set", expectedBootID: "boot")
            var frames = endpoint.surfaces.makeAsyncIterator()
            _ = try await frames.next()
            let text = "first\nsecond\n"
            try await endpoint.sendText(text, paneID: "phone", bootID: "boot", projectionRevision: 3, paste: true)
            var lines: [Substring] = []
            for _ in 0..<100 {
                lines = try String(contentsOf: record).split(separator: "\n")
                if lines.count == 3 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            var expected = Data([13])
            HerdrEndpointWire.appendString("phone", to: &expected)
            expected.append(contentsOf: [1, 3])
            HerdrEndpointWire.appendString(text, to: &expected)
            XCTAssertEqual(lines.last.map(String.init), expected.map { String(format: "%02x", $0) }.joined())
        }
    }

    func testInputLeaseSurvivesMetadataButEndsWhenSelectionChanges() async throws {
        for mode in ["input_metadata", "input_navigation"] {
            try await withFixture(mode) { endpoint, record in
                _ = try await endpoint.connect(socketPath: record.deletingLastPathComponent().appendingPathComponent("test.sock").path)
                _ = try await endpoint.request(method: "client_shell.surface.set", expectedBootID: "boot")
                var frames = endpoint.surfaces.makeAsyncIterator()
                while let frame = try await frames.next() {
                    if frame.projectionRevision == 5 { break }
                }
                do {
                    try await endpoint.sendText("queued", paneID: "phone", bootID: "boot", projectionRevision: 3)
                    XCTAssertEqual(mode, "input_metadata", "Navigation must reject input from the previous selection")
                } catch {
                    XCTAssertEqual(mode, "input_navigation", "Metadata updates must preserve queued input")
                    XCTAssertEqual(error as? HerdrEndpointError, .staleIdentity)
                }
                if mode == "input_navigation" {
                    XCTAssertEqual(try String(contentsOf: record).split(separator: "\n").count, 2)
                    try await endpoint.sendText("fresh", paneID: "phone", bootID: "boot", projectionRevision: 5)
                }
            }
        }
    }

    func testCancelledResizeCannotWriteToTheServer() async throws {
        try await withFixture("success") { endpoint, record in
            _ = try await endpoint.connect(socketPath: record.deletingLastPathComponent().appendingPathComponent("test.sock").path)
            let resize = Task {
                while !Task.isCancelled { await Task.yield() }
                try await endpoint.resize(columns: 99, rows: 44)
            }
            resize.cancel()
            do { try await resize.value; XCTFail("Expected cancelled resize rejection") }
            catch { XCTAssertTrue(error is CancellationError) }
            _ = try await endpoint.request(method: "client_shell.surface.set", expectedBootID: "boot")
            XCTAssertEqual(try String(contentsOf: record).split(separator: "\n").count, 2)
        }
    }

    func testCancellationClosesTheBlockedReader() async throws {
        try await withFixture("request_stall") { endpoint, record in
            _ = try await endpoint.connect(socketPath: record.deletingLastPathComponent().appendingPathComponent("test.sock").path)
            let request = Task { try await endpoint.request(method: "client_shell.surface.set", expectedBootID: "boot") }
            for _ in 0..<100 {
                if try String(contentsOf: record).split(separator: "\n").count == 2 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            request.cancel()
            let began = ContinuousClock.now
            do { _ = try await request.value; XCTFail("Expected cancellation") } catch {}
            XCTAssertLessThan(began.duration(to: .now), .seconds(1))
            XCTAssertEqual(try String(contentsOf: record).split(separator: "\n").count, 2)
        }
    }

    func testWrongResponseIdentityClosesTheConnection() async throws {
        try await withFixture("wrong_response") { endpoint, record in
            _ = try await endpoint.connect(socketPath: record.deletingLastPathComponent().appendingPathComponent("test.sock").path)
            do {
                _ = try await endpoint.request(method: "client_shell.surface.set", expectedBootID: "boot")
                XCTFail("Expected response identity rejection")
            } catch { XCTAssertEqual(error as? HerdrEndpointError, .staleIdentity) }
        }
    }

    func testSemanticSurfaceAndPatchProduceTheExpectedGrid() async throws {
        try await withFixture("surface") { endpoint, record in
            _ = try await endpoint.connect(socketPath: record.deletingLastPathComponent().appendingPathComponent("test.sock").path)
            let deadline = Task {
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { endpoint.disconnect() }
            }
            defer { deadline.cancel() }
            _ = try await endpoint.request(method: "client_shell.surface.set", expectedBootID: "boot")
            var frames = endpoint.surfaces.makeAsyncIterator()
            var result = try await frames.next()
            if result?.revision == 1 { result = try await frames.next() }
            let patched = try XCTUnwrap(result)
            XCTAssertEqual(patched.revision, 2)
            XCTAssertEqual(patched.grid.cells.map(\.symbol), ["B"])
            let ansi = String(decoding: EndpointANSI.render(patched.grid), as: UTF8.self)
            XCTAssertTrue(ansi.contains("38;2;1;2;3"))
            XCTAssertTrue(ansi.contains("B"))
            XCTAssertEqual(patched.panes.first?.paneID, "phone")
        }
    }

    func testHistoryUsesNativeLineEndForBothViewportWidthsAndRefreshesStaleMotion() async throws {
        for mode in ["history_width", "history_narrow", "history_width_stale", "history_truncated"] {
            try await withFixture(mode) { endpoint, record in
                var surfaces = endpoint.surfaces.makeAsyncIterator()
                _ = try await endpoint.connect(socketPath: record.deletingLastPathComponent().appendingPathComponent("test.sock").path)
                _ = try await endpoint.request(method: "client_shell.surface.set", expectedBootID: "boot")
                let initial = try await surfaces.next()
                let request = try EndpointTextRequest.history(surface: XCTUnwrap(initial), paneID: "phone")
                let result = try await endpoint.readHistory(request)
                let truncated = mode == "history_truncated"
                let first = truncated ? 200 : 0, total = truncated ? 1200 : 400
                XCTAssertEqual(result.requestID, request.id)
                XCTAssertEqual(result.text, (first..<total).map { String(format: "row %03d wrapped 👩🏽‍💻 tail\n", $0) }.joined())
                XCTAssertEqual(result.truncated, truncated)
                let calls = try String(contentsOfFile: record.path + ".history").split(separator: "\n").map {
                    try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
                }
                let stale = mode == "history_width_stale"
                XCTAssertEqual(calls.compactMap { $0["method"] as? String },
                    stale ? ["pane.copy_motion", "pane.copy_motion", "pane.selection.read"] : ["pane.copy_motion", "pane.selection.read"])
                let params = calls.compactMap { $0["params"] as? [String: Any] }
                XCTAssertTrue(params.allSatisfy { $0["pane_id"] as? String == "phone" })
                for motion in params.dropLast() {
                    XCTAssertEqual(motion["motion"] as? String, "line_end")
                    XCTAssertEqual(motion["cursor"] as? [String: Int], ["row": total - 1, "col": 0])
                }
                let last = try XCTUnwrap(params.last)
                XCTAssertEqual(last["anchor"] as? [String: Int], ["row": first, "col": 0])
                XCTAssertEqual(last["cursor"] as? [String: Int], ["row": total - 1, "col": stale ? 40 : 50])
                XCTAssertEqual(params.compactMap { $0["content_revision"] as? Int }, stale ? [4, 6, 6] : [4, 4])
            }
        }
    }

    func testHistoryRejectsInvalidNativeLineEndMetadataBeforeSelection() async throws {
        for mode in ["history_invalid_row", "history_bad_pane", "history_bad_row", "history_bad_revision",
                     "history_bad_type", "history_bad_column", "history_negative_column", "history_fractional_column"] {
            try await withFixture(mode) { endpoint, record in
                var surfaces = endpoint.surfaces.makeAsyncIterator()
                _ = try await endpoint.connect(socketPath: record.deletingLastPathComponent().appendingPathComponent("test.sock").path)
                _ = try await endpoint.request(method: "client_shell.surface.set", expectedBootID: "boot")
                let initial = try await surfaces.next()
                let request = try EndpointTextRequest.history(surface: XCTUnwrap(initial), paneID: "phone")
                do {
                    _ = try await endpoint.readHistory(request)
                    XCTFail("Invalid line-end metadata cannot produce a history capture: \(mode)")
                } catch {
                    if mode == "history_invalid_row" {
                        guard case HerdrClientError.remote(let code, _) = error else { throw error }
                        XCTAssertEqual(code, "copy_motion_unavailable")
                    } else { XCTAssertEqual(error as? HerdrEndpointError, .malformed, mode) }
                }
                let calls = try String(contentsOfFile: record.path + ".history").split(separator: "\n")
                XCTAssertEqual(calls.count, 1, "Only the line-end request may run: \(mode)")
            }
        }
    }

    func testIsolatedNativeEndpointHandshake() async throws {
        guard let rootPath = ProcessInfo.processInfo.environment["RAI_ENDPOINT_TEST_ROOT"] else {
            throw XCTSkip("Set RAI_ENDPOINT_TEST_ROOT to an owned app lab for native Herdr verification")
        }
        let root = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath()
        let temporary = URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath()
        let owner = try String(contentsOf: root.appendingPathComponent(".rai-lab-owned"))
        guard root.deletingLastPathComponent().path == temporary.path,
              root.lastPathComponent.hasPrefix("rai09-"), owner.hasPrefix("gr.krig.rai.lab.") else {
            throw HerdrEndpointError.staleIdentity
        }
        let endpoint = HerdrEndpointConnection()
        defer { endpoint.disconnect() }
        let snapshot = try await endpoint.connect(socketPath: root.appendingPathComponent("config/herdr/sessions/lab/herdr-client.sock").path)
        XCTAssertFalse(snapshot.workspaces.isEmpty)
        let welcome = await endpoint.welcome
        XCTAssertEqual(welcome?.generation, 1)
        let result = try await endpoint.request(method: "client_shell.surface.set", params: ["active": .bool(false)], expectedBootID: snapshot.bootID)
        XCTAssertEqual(result.objectValue?["active"], .bool(false))
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { endpoint.disconnect() }
        }
        defer { watchdog.cancel() }
        _ = try await endpoint.request(method: "client_shell.surface.set", params: ["active": .bool(true)], expectedBootID: snapshot.bootID)
        var frames = endpoint.surfaces.makeAsyncIterator()
        let firstSurface = try await frames.next()
        let surface = try XCTUnwrap(firstSurface)
        XCTAssertEqual(surface.bootID, snapshot.bootID)
        XCTAssertEqual(surface.grid.cells.count, Int(surface.grid.width) * Int(surface.grid.height))
        XCTAssertFalse(surface.panes.isEmpty)
        XCTAssertFalse(EndpointANSI.render(surface.grid).isEmpty)
    }

    private func withFixture(
        _ mode: String, run: (HerdrEndpointConnection, URL) async throws -> Void
    ) async throws {
        let root = URL(fileURLWithPath: "/tmp/rai-endpoint-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let socket = root.appendingPathComponent("test.sock")
        let record = root.appendingPathComponent("requests.jsonl")
        let script = try XCTUnwrap(Bundle.module.url(forResource: "fake_endpoint_server", withExtension: "py", subdirectory: "Fixtures"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, socket.path, mode, record.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let stopped = expectation(description: "endpoint fixture stopped")
        process.terminationHandler = { _ in stopped.fulfill() }
        let endpoint = HerdrEndpointConnection()
        defer {
            endpoint.disconnect()
            if process.isRunning { process.terminate() }
            try? FileManager.default.removeItem(at: root)
        }
        try process.run()
        for _ in 0..<300 {
            if FileManager.default.fileExists(atPath: socket.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        var failure: Error?
        do { try await run(endpoint, record) } catch { failure = error }
        endpoint.disconnect()
        if process.isRunning { process.terminate() }
        await fulfillment(of: [stopped], timeout: 5)
        if let failure { throw failure }
    }
}
