import XCTest
@testable import rai

final class HerdListLayoutTests: XCTestCase {
    func testTriageOnShowsGroups() {
        XCTAssertEqual(
            HerdListLayout.resolve(triageEnabled: true, filter: nil),
            .triage
        )
    }

    func testTriageOnWithFilterShowsOneFlatSection() {
        XCTAssertEqual(
            HerdListLayout.resolve(triageEnabled: true, filter: .working),
            .filtered(.working)
        )
    }

    func testTriageOffIsJustTheSpaces() {
        XCTAssertEqual(
            HerdListLayout.resolve(triageEnabled: false, filter: nil),
            .plain
        )
    }

    func testTriageOffIgnoresAStaleFilter() {
        // A segment tapped before the toggle went off must not resurface a
        // filtered view on a screen that no longer shows the pulse line.
        XCTAssertEqual(
            HerdListLayout.resolve(triageEnabled: false, filter: .needsYou),
            .plain
        )
    }

    func testDefaultsKeyIsStable() {
        // Persisted on the device; renaming it would silently reset users.
        XCTAssertEqual(HerdListLayout.triageDefaultsKey, "triageGroupsEnabled")
    }
}
