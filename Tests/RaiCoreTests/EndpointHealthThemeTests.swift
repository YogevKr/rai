import Foundation
import XCTest
@testable import RaiCore

final class EndpointHealthThemeTests: XCTestCase {
    private func theme(_ appearance: EndpointHostTheme.Appearance = .dark, background: UInt32 = 0x112233,
                       changedIndex: Int? = nil) throws -> EndpointHostTheme {
        var palette = (0..<256).map { UInt32($0) }
        if let changedIndex { palette[changedIndex] = 0xaabbcc }
        return try EndpointHostTheme(foreground: 0xabcdef, background: background, palette: palette, appearance: appearance)
    }

    func testNativeThemeTagsColorsAndCompletePalette() throws {
        let frames = try theme().frames(previous: nil)
        XCTAssertEqual(frames.count, 4)
        XCTAssertEqual(frames[0], Data([17, 2, 0]))
        XCTAssertEqual(frames[1], Data([17, 0, 0, 0xab, 0xcd, 0xef]))
        XCTAssertEqual(frames[2], Data([17, 0, 1, 0x11, 0x22, 0x33]))
        var palette = EndpointBinaryReader(data: frames[3])
        XCTAssertEqual(try palette.integer(), 17)
        XCTAssertEqual(try palette.integer(), 1)
        XCTAssertEqual(try palette.integer(), 256)
        for index in 0..<256 {
            XCTAssertEqual(try palette.byte(), UInt8(index))
            XCTAssertEqual(try palette.byte(), 0)
            XCTAssertEqual(try palette.byte(), 0)
            XCTAssertEqual(try palette.byte(), UInt8(index))
        }
        XCTAssertTrue(palette.isAtEnd)
    }

    func testThemeDiffSendsColorsBeforeChangedAppearance() throws {
        let old = try theme()
        XCTAssertEqual(old.frames(previous: old), [])
        let changed = try theme(.light, background: 0x334455, changedIndex: 255).frames(previous: old)
        XCTAssertEqual(changed, [Data([17, 0, 1, 0x33, 0x44, 0x55]),
                                 Data([17, 1, 1, 255, 0xaa, 0xbb, 0xcc]), Data([17, 2, 1])])
    }

    func testThemeRejectsIncompletePaletteAndInvalidRGB() {
        for count in [0, 255, 257] {
            XCTAssertThrowsError(try EndpointHostTheme(foreground: 0, background: 0,
                palette: Array(repeating: 0, count: count), appearance: .dark))
        }
        XCTAssertThrowsError(try EndpointHostTheme(foreground: 0x1000000, background: 0,
            palette: Array(repeating: 0, count: 256), appearance: .dark))
        XCTAssertThrowsError(try EndpointHostTheme(foreground: 0, background: 0,
            palette: Array(repeating: UInt32.max, count: 256), appearance: .dark))
        XCTAssertThrowsError(try HerdrEndpointWire.decode(Data([3, 0])))
    }

    func testQuietDaemonAnswersAutomaticAndExplicitProbes() async throws {
        try await withPeer("quiet") { endpoint, record, _ in
            try await waitForFrames(record, count: 3)
            try await Task.sleep(for: .milliseconds(450))
            try await endpoint.checkHealth(timeout: .seconds(1))
            let frames = try self.frames(record)
            XCTAssertTrue(frames.dropFirst().allSatisfy { $0 == HerdrEndpointWire.control(kind: HerdrEndpointWire.healthPing, data: "") })
        }
    }

    func testCompleteOldMessagesSatisfyHealthWithoutChangingSelection() async throws {
        try await withPeer("old_snapshot") { endpoint, _, _ in
            try await endpoint.checkHealth(timeout: .seconds(1))
            let snapshot = await endpoint.snapshot
            XCTAssertEqual(snapshot?.revision, 3)
            XCTAssertEqual(snapshot?.focusedPaneID, "pane")
        }
    }

    func testQuietAndPartialMessagesCannotExtendHealthDeadline() async throws {
        for mode in ["stall", "partial_prefix", "partial_payload", "dribble"] {
            try await withPeer(mode) { endpoint, record, _ in
                let began = ContinuousClock.now
                do {
                    try await endpoint.checkHealth(timeout: .milliseconds(140))
                    XCTFail("Expected timeout: \(mode)")
                } catch { XCTAssertEqual(error as? HerdrEndpointError, .timedOut, mode) }
                XCTAssertLessThan(began.duration(to: .now), .seconds(1))
                XCTAssertEqual(try self.frames(record).count, 2, "No probe replay")
                do { try await endpoint.resize(columns: 80, rows: 24); XCTFail("Expected failed transport") }
                catch { XCTAssertEqual(error as? HerdrEndpointError, .timedOut) }
            }
        }
    }

    func testAutomaticProbeTimeoutClosesStreams() async throws {
        try await withPeer("stall") { endpoint, record, _ in
            var titles = endpoint.windowTitles.makeAsyncIterator()
            do {
                _ = try await titles.next() // Failure emits the title reset first.
                _ = try await titles.next()
                XCTFail("Expected automatic health failure")
            } catch { XCTAssertEqual(error as? HerdrEndpointError, .timedOut) }
            XCTAssertEqual(try self.frames(record).count, 2)
        }
    }

    func testPartialFrameCompletesWithoutLosingFramingOrProbe() async throws {
        try await withPeer("partial_before_probe") { endpoint, _, _ in
            try await endpoint.checkHealth(timeout: .seconds(1))
            _ = try await endpoint.request(method: "client_shell.surface.set", expectedBootID: "boot")
            try await endpoint.checkHealth(timeout: .seconds(1))
        }
    }

    func testMalformedAndChangedGenerationMessagesFailHealth() async throws {
        for mode in ["malformed", "new_boot"] {
            try await withPeer(mode) { endpoint, _, _ in
                do { try await endpoint.checkHealth(); XCTFail("Expected invalid peer") }
                catch { XCTAssertEqual(error as? HerdrEndpointError, mode == "malformed" ? .malformed : .staleIdentity) }
            }
        }
    }

    func testMissingCapabilityRejectsProbeWithoutClosingTransport() async throws {
        try await withPeer("no_capability") { endpoint, record, _ in
            let supported = await endpoint.supportsHealthChecks
            XCTAssertFalse(supported)
            do { try await endpoint.checkHealth(); XCTFail("Expected missing capability") }
            catch { guard case .incompatible = error as? HerdrEndpointError else { return XCTFail("Wrong error: \(error)") } }
            try await Task.sleep(for: .milliseconds(150))
            try await endpoint.setHostTheme(self.theme(), expectedBootID: "boot")
            _ = try await endpoint.request(method: "client_shell.surface.set", expectedBootID: "boot")
            XCTAssertEqual(try self.frames(record).map { $0[0] }, [20, 17, 17, 17, 17, 15])
        }
    }

    func testHealthMessagesDoNotExtendRequestDeadline() async throws {
        try await withPeer("request_stall") { endpoint, record, _ in
            do {
                _ = try await endpoint.request(method: "client_shell.surface.set", expectedBootID: "boot", timeout: .milliseconds(200))
                XCTFail("Expected request timeout despite pongs")
            } catch { XCTAssertEqual(error as? HerdrEndpointError, .timedOut) }
            XCTAssertEqual(try self.frames(record).filter { $0[0] == 15 }.count, 1)
        }
    }

    func testPongsDoNotExtendInitialSnapshotDeadline() async throws {
        try await withPeer("startup_health", connect: false) { endpoint, record, socket in
            do {
                _ = try await endpoint.connect(socketPath: socket.path, timeout: .milliseconds(200))
                XCTFail("Expected snapshot timeout")
            } catch { XCTAssertEqual(error as? HerdrEndpointError, .timedOut) }
            XCTAssertGreaterThan(try self.frames(record).count, 1)
        }
    }

    func testOperationRejectionKeepsDaemonHealthAndThemeCache() async throws {
        try await withPeer("reject") { endpoint, record, _ in
            let theme = try self.theme()
            try await endpoint.setHostTheme(theme, expectedBootID: "boot")
            do {
                _ = try await endpoint.request(method: "client_shell.surface.set", expectedBootID: "boot")
                XCTFail("Expected operation rejection")
            } catch { guard case .remote = error as? HerdrClientError else { return XCTFail("Wrong error: \(error)") } }
            try await endpoint.checkHealth()
            try await endpoint.setHostTheme(theme, expectedBootID: "boot")
            XCTAssertEqual(try self.frames(record).filter { $0[0] == 17 }.count, 4)
        }
    }

    func testThemeWritesStayOrderedWithInputAndResetOnNewConnections() async throws {
        for _ in 0..<2 {
            try await withPeer("no_capability") { endpoint, record, _ in
                let old = try self.theme()
                try await endpoint.setHostTheme(old, expectedBootID: "boot")
                try await endpoint.resize(columns: 99, rows: 44)
                try await endpoint.setHostTheme(old, expectedBootID: "boot")
                try await endpoint.setHostTheme(self.theme(.light, background: 0x334455, changedIndex: 255), expectedBootID: "boot")
                _ = try await endpoint.request(method: "client_shell.surface.set", expectedBootID: "boot")
                XCTAssertEqual(try self.frames(record).map { $0[0] }, [20, 17, 17, 17, 17, 12, 17, 17, 17, 15])
                do { try await endpoint.setHostTheme(old, expectedBootID: "old"); XCTFail("Expected stale target") }
                catch { XCTAssertEqual(error as? HerdrEndpointError, .staleIdentity) }
                endpoint.disconnect()
                do { try await endpoint.setHostTheme(old, expectedBootID: "boot"); XCTFail("Expected disconnected target") }
                catch {}
            }
        }
    }

    func testCancelledHealthProbeClosesConnectionWithoutReplay() async throws {
        try await withPeer("stall") { endpoint, record, _ in
            let probe = Task { try await endpoint.checkHealth() }
            try await waitForFrames(record, count: 2)
            probe.cancel()
            do { try await probe.value; XCTFail("Expected cancellation") } catch {}
            XCTAssertEqual(try self.frames(record).count, 2)
        }
    }

    func testConcurrentHealthCallersShareOneOrderedProbe() async throws {
        try await withPeer("delayed_pong") { endpoint, record, _ in
            let first = Task { try await endpoint.checkHealth() }
            try await waitForFrames(record, count: 2)
            let second = Task { try await endpoint.checkHealth() }
            try await first.value
            try await second.value
            XCTAssertEqual(try self.frames(record).count, 2)
        }
    }

    func testThemeBatchPreservesCommittedTextOrder() async throws {
        try await withPeer("input_order") { endpoint, record, _ in
            var surfaces = endpoint.surfaces.makeAsyncIterator()
            _ = try await surfaces.next()
            try await endpoint.sendText("first", paneID: "pane", bootID: "boot", projectionRevision: 3)
            try await endpoint.setHostTheme(self.theme(), expectedBootID: "boot")
            try await endpoint.sendText("second", paneID: "pane", bootID: "boot", projectionRevision: 3)
            _ = try await endpoint.request(method: "client_shell.surface.set", expectedBootID: "boot")
            let frames = try self.frames(record)
            XCTAssertEqual(frames.map { $0[0] }, [20, 13, 17, 17, 17, 17, 13, 15])
            XCTAssertTrue(frames[1].suffix(5) == Data("first".utf8))
            XCTAssertTrue(frames[6].suffix(6) == Data("second".utf8))
        }
    }

    func testOwnedNativeDaemonHealthAndOSCThemeQueries() async throws {
        guard let path = ProcessInfo.processInfo.environment["RAI_ENDPOINT_TEST_ROOT"] else {
            throw XCTSkip("Set RAI_ENDPOINT_TEST_ROOT to this worker's owned native app lab")
        }
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let temporary = URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath()
        guard root.deletingLastPathComponent().path == temporary.path, root.lastPathComponent.hasPrefix("rai09-"),
              try String(contentsOf: root.appendingPathComponent(".rai-lab-owned")).hasPrefix("gr.krig.rai.lab.") else {
            throw HerdrEndpointError.staleIdentity
        }
        let endpoint = HerdrEndpointConnection()
        defer { endpoint.disconnect() }
        let snapshot = try await endpoint.connect(socketPath: root.appendingPathComponent("config/herdr/sessions/lab/herdr-client.sock").path)
        let welcome = await endpoint.welcome
        XCTAssertEqual(welcome?.serverVersion, "0.9.3")
        try await endpoint.checkHealth(timeout: .seconds(2))
        _ = try await endpoint.request(method: "client_shell.surface.set", params: ["active": .bool(true)], expectedBootID: snapshot.bootID)
        var surfaces = endpoint.surfaces.makeAsyncIterator()
        _ = try await surfaces.next()
        let pane = try XCTUnwrap(snapshot.focusedPaneID)
        let script = try XCTUnwrap(Bundle.module.url(forResource: "endpoint_theme_query", withExtension: "py", subdirectory: "Fixtures"))
        var palette = Array(repeating: UInt32(0), count: 256)
        palette[0] = 0x010203
        palette[255] = 0xaabbcc
        for (index, background) in [UInt32(0x112233), 0x334455].enumerated() {
            let theme = try EndpointHostTheme(foreground: 0xabcdef, background: background, palette: palette,
                                             appearance: index == 0 ? .dark : .light)
            try await endpoint.setHostTheme(theme, expectedBootID: snapshot.bootID)
            let record = root.appendingPathComponent("theme-query-\(UUID().uuidString).json")
            let quote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let latest = await endpoint.snapshot
            let current = try XCTUnwrap(latest)
            try await endpoint.sendText("/usr/bin/python3 \(quote(script.path)) \(quote(record.path))", paneID: pane,
                                        bootID: current.bootID, projectionRevision: current.revision)
            try await endpoint.sendInput(.key(EndpointKey(code: .special(.enter))), paneID: pane,
                                         bootID: current.bootID, projectionRevision: current.revision)
            for _ in 0..<400 {
                if FileManager.default.fileExists(atPath: record.path) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let result = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: record))
            let response = try XCTUnwrap(result["response"]).lowercased()
            XCTAssertTrue(response.contains("10;rgb:abab/cdcd/efef"), response)
            XCTAssertTrue(response.contains(index == 0 ? "11;rgb:1111/2222/3333" : "11;rgb:3333/4444/5555"), response)
            XCTAssertTrue(response.contains("4;0;rgb:0101/0202/0303"), response)
            XCTAssertTrue(response.contains("4;255;rgb:aaaa/bbbb/cccc"), response)
        }
        try await endpoint.checkHealth(timeout: .seconds(2))
    }

    private func frames(_ record: URL) throws -> [Data] {
        try String(contentsOf: record).split(separator: "\n").map { line in
            let bytes = Array(line.utf8)
            return Data(stride(from: 0, to: bytes.count, by: 2).map { index in
                UInt8(String(decoding: bytes[index..<index + 2], as: UTF8.self), radix: 16)!
            })
        }
    }

    private func waitForFrames(_ record: URL, count: Int) async throws {
        for _ in 0..<200 {
            if try frames(record).count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Peer did not receive expected frames")
    }

    private func withPeer(_ mode: String, connect: Bool = true,
                          run: (HerdrEndpointConnection, URL, URL) async throws -> Void) async throws {
        let root = URL(fileURLWithPath: "/tmp/rai-health-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let socket = root.appendingPathComponent("peer.sock"), record = root.appendingPathComponent("frames")
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "fake_endpoint_health", withExtension: "py", subdirectory: "Fixtures"))
        let peer = Process()
        peer.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        peer.arguments = [fixture.path, socket.path, mode, record.path]
        let errors = root.appendingPathComponent("peer-errors")
        FileManager.default.createFile(atPath: errors.path, contents: nil)
        peer.standardError = try FileHandle(forWritingTo: errors)
        peer.standardOutput = FileHandle.nullDevice
        let stopped = expectation(description: "owned peer stopped")
        peer.terminationHandler = { _ in stopped.fulfill() }
        let endpoint = HerdrEndpointConnection(healthQuietInterval: .milliseconds(40), healthTimeout: .milliseconds(350))
        defer {
            endpoint.disconnect()
            if peer.isRunning { peer.terminate() }
            try? FileManager.default.removeItem(at: root)
        }
        try peer.run()
        for _ in 0..<300 {
            if FileManager.default.fileExists(atPath: socket.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        var failure: Error?
        do {
            if connect { _ = try await endpoint.connect(socketPath: socket.path) }
            try await run(endpoint, record, socket)
        } catch { failure = error }
        endpoint.disconnect()
        if peer.isRunning { peer.terminate() }
        await fulfillment(of: [stopped], timeout: 5)
        XCTAssertEqual(try String(contentsOf: errors), "", "Fixture failure")
        if let failure { throw failure }
    }
}
