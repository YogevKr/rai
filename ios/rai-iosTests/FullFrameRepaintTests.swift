import RaiCore
import SwiftTerm
import UIKit
import XCTest
@testable import rai

@MainActor
final class FullFrameRepaintTests: XCTestCase {
    private func view(rows: Int = 4, cols: Int = 80) -> GridReadableTerminalView {
        let view = GridReadableTerminalView(frame: CGRect(x: 0, y: 0, width: 650, height: 60))
        view.changeScrollback(2_000)
        view.pinGridSize(cols: cols, rows: rows)
        return view
    }

    /// A frame in herdr's observe shape: clear, cell-addressed rows, cursor.
    private func frame(_ rows: [String], cursor: (row: Int, col: Int) = (1, 1), hideCursor: Bool = true) -> Data {
        let paint = rows.enumerated().map { "\u{1B}[\($0.offset + 1);1H\u{1B}[0;39;49m\($0.element)" }.joined()
        let visibility = hideCursor ? "\u{1B}[?25l" : "\u{1B}[?25h"
        return Data(("\u{1B}[2J" + paint + "\u{1B}[\(cursor.row);\(cursor.col)H" + visibility).utf8)
    }

    private let grid = PaneGridSize(cols: 80, rows: 4)

    func testIdenticalFullFrameKeepsTheRetainedScreen() {
        let view = view()
        let baseline = frame(["• Ran node", "  └ done", "", "› Ask Codex"], cursor: (4, 12))
        XCTAssertEqual(view.receiveFrame(baseline, kind: .full, grid: grid), .followLive)
        XCTAssertEqual(view.fullRepaints, 1)
        let cells = view.getTerminal().getBufferAsData()

        view.awaitNextConnectionFrame()
        XCTAssertEqual(view.receiveFrame(baseline, kind: .full, grid: grid), .followLive)
        XCTAssertEqual(view.fullRepaints, 1, "An unchanged baseline must not clear and repaint")
        XCTAssertTrue(view.hasLiveFrame, "The retained screen is live again after the baseline")
        XCTAssertEqual(view.getTerminal().getBufferAsData(), cells)
        XCTAssertEqual(view.receiveFrame(Data("\u{1B}[2;5Hnow".utf8), kind: .delta, grid: nil), .applied)
        XCTAssertTrue(view.liveGridText().contains("  └ now"), "Deltas keep applying to the kept screen")
    }

    func testChangedTextRepaints() {
        let view = view()
        view.receiveFrame(frame(["one", "two"]), kind: .full, grid: grid)
        view.awaitNextConnectionFrame()
        view.receiveFrame(frame(["one", "three"]), kind: .full, grid: grid)
        XCTAssertEqual(view.fullRepaints, 2)
        XCTAssertTrue(view.liveGridText().contains("three"))
    }

    func testChangedGraphemeClusterRepaints() throws {
        let view = view()
        view.receiveFrame(frame(["\u{1F469}\u{200D}\u{1F4BB} working"]), kind: .full, grid: grid)
        view.awaitNextConnectionFrame()
        view.receiveFrame(frame(["\u{1F469}\u{200D}\u{1F4BB} working"]), kind: .full, grid: grid)
        XCTAssertEqual(view.fullRepaints, 1, "The same cluster renders the same screen")
        view.awaitNextConnectionFrame()
        view.receiveFrame(frame(["\u{1F468}\u{200D}\u{1F4BB} working"]), kind: .full, grid: grid)
        XCTAssertEqual(view.fullRepaints, 2, "A different cluster in the same cell is a change")
        let terminal = view.getTerminal()
        let cell = try XCTUnwrap(terminal.getCharData(col: 0, row: 0))
        XCTAssertEqual(terminal.getCharacter(for: cell), "\u{1F468}\u{200D}\u{1F4BB}")
    }

    func testChangedAttributesRepaint() {
        let view = view()
        view.receiveFrame(frame(["plain"]), kind: .full, grid: grid)
        view.awaitNextConnectionFrame()
        let bold = Data("\u{1B}[2J\u{1B}[1;1H\u{1B}[0;1;39;49mplain\u{1B}[1;1H\u{1B}[?25l".utf8)
        view.receiveFrame(bold, kind: .full, grid: grid)
        XCTAssertEqual(view.fullRepaints, 2, "Same text with new styling is a change")
    }

    func testDeltaAfterBaselineMakesTheSameBaselineRepaint() {
        let view = view()
        let baseline = frame(["one", "two"])
        view.receiveFrame(baseline, kind: .full, grid: grid)
        view.receiveFrame(Data("\u{1B}[2;1Htwo!".utf8), kind: .delta, grid: nil)
        view.awaitNextConnectionFrame()
        view.receiveFrame(baseline, kind: .full, grid: grid)
        XCTAssertEqual(view.fullRepaints, 2, "The screen moved on; the old baseline must restore it")
        XCTAssertFalse(view.liveGridText().contains("two!"))
    }

    func testCursorMoveAloneRepaints() {
        let view = view()
        view.receiveFrame(frame(["prompt"], cursor: (1, 7)), kind: .full, grid: grid)
        view.awaitNextConnectionFrame()
        view.receiveFrame(frame(["prompt"], cursor: (2, 1)), kind: .full, grid: grid)
        XCTAssertEqual(view.fullRepaints, 2)
        XCTAssertEqual(view.getTerminal().getCursorLocation().y, 1)
    }

    func testCursorVisibilityChangeRepaints() {
        let view = view()
        view.receiveFrame(frame(["prompt"], hideCursor: true), kind: .full, grid: grid)
        view.awaitNextConnectionFrame()
        view.receiveFrame(frame(["prompt"], hideCursor: false), kind: .full, grid: grid)
        XCTAssertEqual(view.fullRepaints, 2)
        view.awaitNextConnectionFrame()
        view.receiveFrame(frame(["prompt"], hideCursor: false), kind: .full, grid: grid)
        XCTAssertEqual(view.fullRepaints, 2, "The visible-cursor baseline is now the retained state")
    }

    func testCursorShapeChangeRepaints() {
        let view = view()
        let bar = frame(["prompt"]) + Data("\u{1B}[5 q".utf8)
        let block = frame(["prompt"]) + Data("\u{1B}[2 q".utf8)
        view.receiveFrame(bar, kind: .full, grid: grid)
        view.awaitNextConnectionFrame()
        view.receiveFrame(bar, kind: .full, grid: grid)
        XCTAssertEqual(view.fullRepaints, 1, "The same shape keeps the screen")
        view.awaitNextConnectionFrame()
        view.receiveFrame(block, kind: .full, grid: grid)
        XCTAssertEqual(view.fullRepaints, 2, "A new cursor shape is a change")
        view.awaitNextConnectionFrame()
        view.receiveFrame(frame(["prompt"]), kind: .full, grid: grid)
        XCTAssertEqual(view.fullRepaints, 2, "A baseline without a shape request keeps the retained shape")
    }

    func testCursorIntentParsesTheLastRequests() {
        let bytes = Data("\u{1B}[?25l\u{1B}[3 q\u{1B}[?2026h\u{1B}[?25h\u{1B}[0 q\u{1B}[?25;1h".utf8)
        let intent = GridReadableTerminalView.cursorIntent(in: bytes)
        XCTAssertEqual(intent.visible, true)
        XCTAssertEqual(intent.style, 0)
        XCTAssertEqual(GridReadableTerminalView.cursorIntent(in: Data("\u{1B}[2J".utf8)), .init())
    }

    func testChangedHyperlinkRepaints() {
        let view = view()
        let linked = Data("\u{1B}[2J\u{1B}[1;1H\u{1B}[0;39;49m\u{1B}]8;;https://a.example\u{1B}\\open\u{1B}]8;;\u{1B}\\\u{1B}[1;1H\u{1B}[?25l".utf8)
        let relinked = Data("\u{1B}[2J\u{1B}[1;1H\u{1B}[0;39;49m\u{1B}]8;;https://b.example\u{1B}\\open\u{1B}]8;;\u{1B}\\\u{1B}[1;1H\u{1B}[?25l".utf8)
        view.receiveFrame(linked, kind: .full, grid: grid)
        view.awaitNextConnectionFrame()
        view.receiveFrame(linked, kind: .full, grid: grid)
        XCTAssertEqual(view.fullRepaints, 1, "The same link keeps the screen")
        view.awaitNextConnectionFrame()
        view.receiveFrame(relinked, kind: .full, grid: grid)
        XCTAssertEqual(view.fullRepaints, 2, "A new link target on the same text is a change")
        view.awaitNextConnectionFrame()
        view.receiveFrame(frame(["open"]), kind: .full, grid: grid)
        XCTAssertEqual(view.fullRepaints, 3, "Dropping the link is a change")
    }

    func testResizedGridRepaints() {
        let view = view()
        view.receiveFrame(frame(["one"]), kind: .full, grid: grid)
        view.awaitNextConnectionFrame()
        view.receiveFrame(frame(["one"]), kind: .full, grid: PaneGridSize(cols: 80, rows: 5))
        XCTAssertEqual(view.fullRepaints, 2)
        XCTAssertEqual(view.getTerminal().rows, 5)
    }

    func testPreviewIsIgnoredOnARetainedScreenAndPaintsAFreshOne() {
        let fresh = view()
        let preview = Data("\u{1B}[H\u{1B}[0m\u{1B}[2mone\u{1B}[0m\r\ntwo\u{1B}[0m".utf8)
        XCTAssertEqual(fresh.receiveFrame(preview, kind: .preview, grid: grid), .followLive)
        XCTAssertTrue(fresh.liveGridText().contains("two"))

        let retained = view()
        retained.receiveFrame(frame(["one", "two"]), kind: .full, grid: grid)
        let cells = retained.getTerminal().getBufferAsData()
        retained.awaitNextConnectionFrame()
        XCTAssertEqual(retained.receiveFrame(preview, kind: .preview, grid: grid), .ignored)
        XCTAssertFalse(retained.hasLiveFrame, "A preview is not a stream baseline")
        XCTAssertEqual(retained.getTerminal().getBufferAsData(), cells)
        XCTAssertEqual(retained.fullRepaints, 1)
        XCTAssertEqual(retained.receiveFrame(frame(["one", "two"]), kind: .full, grid: grid), .followLive)
        XCTAssertEqual(retained.fullRepaints, 1, "The matching baseline keeps the screen")
        XCTAssertTrue(retained.hasLiveFrame)
    }

    func testConnectionMapsSequenceZeroToPreview() {
        var kinds: [PaneFrameKind] = []
        let connection = BridgeConnection(messageSender: { _ in })
        _ = connection.addPaneFrameHandler(for: "pane") { _, kind, _ in kinds.append(kind) }
        let bytes = Data("\u{1B}[Hx".utf8).base64EncodedString()
        connection.handle(.paneFrame(paneID: "pane", bytesBase64: bytes, full: true, seq: 0, cols: 80, rows: 4))
        connection.handle(.paneFrame(paneID: "pane", bytesBase64: bytes, full: true, seq: 1, cols: 80, rows: 4))
        connection.handle(.paneFrame(paneID: "pane", bytesBase64: bytes, full: false, seq: 2, cols: 80, rows: 4))
        XCTAssertEqual(kinds, [.preview, .full, .delta])
        connection.disconnect()
    }
}
