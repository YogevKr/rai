import XCTest
@testable import RaiApp

final class RaiInstanceGuardTests: XCTestCase {
    func testIgnoresCurrentProcessAndOtherBundleIdentifiers() {
        let running = [
            RaiInstanceGuard.Instance(bundleIdentifier: "gr.krig.rai", processIdentifier: 10),
            RaiInstanceGuard.Instance(bundleIdentifier: "gr.krig.rai.dev", processIdentifier: 11),
            RaiInstanceGuard.Instance(bundleIdentifier: "gr.krig.rai", processIdentifier: 12),
        ]

        XCTAssertEqual(
            RaiInstanceGuard.duplicate(
                bundleIdentifier: "gr.krig.rai",
                currentProcessIdentifier: 10,
                running: running
            )?.processIdentifier,
            12
        )
    }

    func testReturnsNoDuplicateForAnIsolatedBundle() {
        let running = [
            RaiInstanceGuard.Instance(bundleIdentifier: "gr.krig.rai.lab.alpha", processIdentifier: 20),
        ]

        XCTAssertNil(
            RaiInstanceGuard.duplicate(
                bundleIdentifier: "gr.krig.rai.lab.beta",
                currentProcessIdentifier: 21,
                running: running
            )
        )
    }
}
