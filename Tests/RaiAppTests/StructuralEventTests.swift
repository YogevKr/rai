import XCTest

@testable import RaiApp

/// Output events must NOT trigger a full snapshot refresh. They arrive as
/// `pane.updated` on the wire (protocol 16 cannot subscribe to
/// `pane.output_changed`; the client substitutes it), and treating them as
/// structural refreshed the snapshot — a herdr CLI spawn, a full decode, and
/// a whole-UI re-render — on every output burst while the user typed.
@MainActor
final class StructuralEventTests: XCTestCase {
    func testOutputEventsAreNotStructural() {
        XCTAssertFalse(RaiModel.isStructuralEvent("pane.output_changed"))
        XCTAssertFalse(RaiModel.isStructuralEvent("pane.updated"))
    }

    func testStructuralEventsStillRefresh() {
        for name in [
            "layout.updated", "pane.created", "pane.closed", "pane.moved",
            "pane.focused", "pane.agent_status_changed", "tab.closed",
            "tab.moved", "workspace.focused", "workspace.moved",
        ] {
            XCTAssertTrue(RaiModel.isStructuralEvent(name), name)
        }
    }
}
