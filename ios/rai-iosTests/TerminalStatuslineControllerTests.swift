import Combine
import RaiCore
import XCTest
@testable import rai

@MainActor
final class TerminalStatuslineControllerTests: XCTestCase {
    // Regression for a self-triggering SwiftUI update loop: the outer view
    // observes `statusline` directly, and `refresh(agent:)` runs inside
    // `updateUIView`. Republishing on every call — even to an equal value —
    // re-invalidates that outer view, which calls updateUIView again,
    // forever. This pinned the main thread and froze the app whenever a
    // pane with a Claude statusline opened.
    func testRefreshDoesNotRepublishAnUnchangedStatusline() {
        let controller = TerminalStatuslineController()
        let grid = "◉ xhigh · /effort\n"
        controller.readGrid = { grid }

        var publishCount = 0
        let cancellable = controller.objectWillChange.sink { publishCount += 1 }
        defer { cancellable.cancel() }

        controller.refresh(agent: "claude")
        XCTAssertEqual(publishCount, 1, "first parse of a non-empty grid publishes once")

        for _ in 0..<50 {
            controller.refresh(agent: "claude")
        }
        XCTAssertEqual(
            publishCount,
            1,
            "identical grid text must not republish — this is what looped forever"
        )
    }

    func testRefreshPublishesWhenTheParsedStatuslineActuallyChanges() {
        let controller = TerminalStatuslineController()
        var grid = "◉ xhigh · /effort\n"
        controller.readGrid = { grid }

        var publishCount = 0
        let cancellable = controller.objectWillChange.sink { publishCount += 1 }
        defer { cancellable.cancel() }

        controller.refresh(agent: "claude")
        XCTAssertEqual(publishCount, 1)

        grid = "◉ low · /effort\n"
        controller.refresh(agent: "claude")
        XCTAssertEqual(publishCount, 2, "a real change must still publish")

        controller.refresh(agent: "claude")
        XCTAssertEqual(publishCount, 2, "and then settle again")
    }
}
