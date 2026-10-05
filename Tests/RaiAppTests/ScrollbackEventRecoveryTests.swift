import Foundation
import RaiCore
import XCTest
@testable import RaiApp

@MainActor
final class ScrollbackEventRecoveryTests: XCTestCase {
    func testOverflowRefreshesScrollStateWhenNoMoreEventsArrive() async throws {
        try await withServer(mode: "events_scroll_overflow") { controller, record in
            let recovered = expectation(description: "final scroll offset recovered without another event")
            var offsets: [Int] = []
            var didRecover = false
            controller.onScrollOffsetChanged = { scroll in
                if offsets.isEmpty {
                    // Hold this consumer while the owned producer fills the buffer.
                    Thread.sleep(forTimeInterval: 0.3)
                }
                offsets.append(scroll.offsetFromBottom)
                if scroll.offsetFromBottom == 0, !didRecover {
                    didRecover = true
                    recovered.fulfill()
                }
            }
            controller.paneID = "w1:p1"
            await fulfillment(of: [recovered], timeout: 10)
            XCTAssertEqual(offsets.first, 50)
            XCTAssertEqual(offsets.last, 0)
            let requests = try String(contentsOf: record).split(separator: "\n")
            XCTAssertEqual(requests.filter { $0.contains("events.subscribe") }.count, 2)
            XCTAssertEqual(requests.filter { $0.contains("session.snapshot") }.count, 2)
            XCTAssertTrue(FileManager.default.fileExists(atPath: record.path + ".events-closed"))
        }
    }

    func testPaneRemovalClosesPendingSnapshotAndSubscription() async throws {
        try await withServer(mode: "events_scroll_snapshot_stall") { controller, record in
            controller.paneID = "w1:p1"
            for _ in 0..<200 {
                if (try? String(contentsOf: record).contains("session.snapshot")) == true { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(try String(contentsOf: record).contains("session.snapshot"))
            controller.paneID = nil
            for _ in 0..<100 {
                if FileManager.default.fileExists(atPath: record.path + ".snapshot-closed"),
                   FileManager.default.fileExists(atPath: record.path + ".events-closed") { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: record.path + ".snapshot-closed"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: record.path + ".events-closed"))
            try await controller.client.scrollPane("w1:p1", offsetFromBottom: 0)
        }
    }

    func testStalledSnapshotTimesOutAndClosesSubscription() async throws {
        try await withServer(mode: "events_scroll_snapshot_stall") { controller, record in
            controller.paneID = "w1:p1"
            for _ in 0..<650 {
                if FileManager.default.fileExists(atPath: record.path + ".snapshot-closed"),
                   FileManager.default.fileExists(atPath: record.path + ".events-closed") { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: record.path + ".snapshot-closed"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: record.path + ".events-closed"))
        }
    }

    func testConcurrentStalledPanesDoNotBlockRecoveryDeadlines() async throws {
        try await withServer(mode: "events_scroll_snapshot_stall") { controller, record in
            let count = ProcessInfo.processInfo.activeProcessorCount + 4
            let panes = (0..<count).map { _ in ScrollbackSelectionController() }
            defer { for pane in panes { pane.paneID = nil; pane.client.disconnect() } }
            let started = ContinuousClock.now
            for pane in panes {
                pane.client = HerdrClient(socketPath: controller.client.socketPath)
                pane.paneID = "w1:p1"
            }
            let closed = URL(fileURLWithPath: record.path + ".snapshot-closed")
            for _ in 0..<1000 {
                if (try? String(contentsOf: closed).split(separator: "\n").count) == count { break }
                if started.duration(to: .now) > .seconds(10) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            // Include connection setup, but finish before the fixture's 12 s watchdog.
            XCTAssertLessThan(started.duration(to: .now), .seconds(10))
            XCTAssertEqual((try? String(contentsOf: closed).split(separator: "\n").count) ?? 0, count)
        }
    }

    private func withServer(mode: String,
                            run: (ScrollbackSelectionController, URL) async throws -> Void) async throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("rai-scroll-events-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let socket = root.appendingPathComponent("test.sock")
        let record = root.appendingPathComponent("requests.jsonl")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("RaiCoreTests/Fixtures/fake_herdr_server.py")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [fixture.path, socket.path, mode, record.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let stopped = expectation(description: "owned fixture stopped")
        process.terminationHandler = { _ in stopped.fulfill() }
        try process.run()
        let controller = ScrollbackSelectionController()
        controller.client = HerdrClient(socketPath: socket.path)
        defer {
            controller.paneID = nil
            controller.client.disconnect()
            if process.isRunning { process.terminate() }
            try? FileManager.default.removeItem(at: root)
        }
        for _ in 0..<300 {
            if FileManager.default.fileExists(atPath: socket.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        var failure: Error?
        do { try await run(controller, record) }
        catch { failure = error }
        controller.paneID = nil
        if process.isRunning { process.terminate() }
        await fulfillment(of: [stopped], timeout: 5)
        if let failure { throw failure }
    }
}
