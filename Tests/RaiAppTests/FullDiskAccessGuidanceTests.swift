import XCTest
@testable import RaiApp

@MainActor
final class FullDiskAccessGuidanceTests: XCTestCase {
    func testShowsOnceAcrossWindowsAndAppRestarts() throws {
        let name = "rai-disk-access-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let guidance = FullDiskAccessGuidance(defaults: defaults)

        XCTAssertTrue(guidance.claimLaunchPresentation())
        XCTAssertFalse(guidance.claimLaunchPresentation(), "A second window must not repeat the dialog")

        let nextLaunch = FullDiskAccessGuidance(defaults: try XCTUnwrap(UserDefaults(suiteName: name)))
        XCTAssertFalse(nextLaunch.claimLaunchPresentation(), "Relaunching must not nag after dismissal or opening Settings")
    }

    func testUpgradeShowsHelpWithoutChangingExistingPreferences() throws {
        let name = "rai-disk-access-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "codexMicroEnabled")

        XCTAssertTrue(FullDiskAccessGuidance(defaults: defaults).claimLaunchPresentation())
        XCTAssertTrue(defaults.bool(forKey: "codexMicroEnabled"))
    }
}
