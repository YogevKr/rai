import Foundation
import RaiCore
import XCTest
@testable import RaiApp

final class PaneFirstFrameCaptureTests: XCTestCase {
    func testVisibleCaptureMakesOneFullNativeGridFrame() async throws {
        let arguments = LockedArguments()
        let frame = await PaneFirstFrameCapture.capture(
            paneID: "pane-7",
            cols: 132,
            rows: 47
        ) { received in
            arguments.set(received)
            return Data("\u{1B}[31mone\r\ntwo\r\n".utf8)
        }

        XCTAssertEqual(
            arguments.value,
            ["pane", "read", "pane-7", "--source", "visible", "--format", "ansi"]
        )
        XCTAssertEqual(frame?.cols, 132)
        XCTAssertEqual(frame?.rows, 47)
        XCTAssertEqual(
            String(data: try XCTUnwrap(frame?.bytes), encoding: .utf8),
            "\u{1B}[H\u{1B}[31mone\r\ntwo\u{1B}[0m"
        )
        guard case let .paneFrame(paneID, _, full, seq, cols, rows) =
            try XCTUnwrap(frame?.message(paneID: "pane-7")) else {
            return XCTFail("Expected paneFrame")
        }
        XCTAssertEqual(paneID, "pane-7")
        XCTAssertTrue(full)
        XCTAssertEqual(seq, 0)
        XCTAssertEqual(cols, 132)
        XCTAssertEqual(rows, 47)
    }

    func testFailedVisibleCaptureSkipsFirstFrame() async {
        let frame = await PaneFirstFrameCapture.capture(
            paneID: "pane-7",
            cols: 80,
            rows: 24,
            run: { _ in nil }
        )

        XCTAssertNil(frame)
    }
}

private final class LockedArguments: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    var value: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: [String]) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}
