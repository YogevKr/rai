import XCTest

@testable import RaiApp

/// High-rate events must NOT trigger an immediate snapshot refresh. Output
/// arrives as `pane.updated` on protocol 16. A new event subscription can also
/// replay a long focus history. Both streams use one trailing refresh instead.
@MainActor
final class StructuralEventTests: XCTestCase {
    func testOutputEventsAreNotStructural() {
        XCTAssertFalse(RaiModel.isStructuralEvent("pane.output_changed"))
        XCTAssertFalse(RaiModel.isStructuralEvent("pane.updated"))
    }

    func testReplayedFocusEventsAreNotStructural() {
        XCTAssertFalse(RaiModel.isStructuralEvent("pane.focused"))
        XCTAssertFalse(RaiModel.isStructuralEvent("workspace.focused"))
    }

    func testStructuralEventsStillRefresh() {
        for name in [
            "layout.updated", "pane.created", "pane.closed", "pane.moved",
            "pane.agent_status_changed", "tab.closed", "tab.moved",
            "workspace.moved",
        ] {
            XCTAssertTrue(RaiModel.isStructuralEvent(name), name)
        }
    }
}
