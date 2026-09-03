import AppKit
import XCTest

@testable import RaiApp

@MainActor
final class PredictiveEchoSettingsTests: XCTestCase {
    func testLocalPredictionDefaultsOffAndRemotePredictionStaysEnabled() throws {
        _ = NSApplication.shared
        let suiteName = "PredictiveEchoSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(userDefaults: defaults)
        XCTAssertFalse(settings.predictiveEchoLocalEnabled)
        XCTAssertNil(
            TerminalPool.enabledPredictiveEchoLocation(
                herdLocation: .local,
                localEnabled: settings.predictiveEchoLocalEnabled
            )
        )
        XCTAssertEqual(
            TerminalPool.enabledPredictiveEchoLocation(
                herdLocation: .remote,
                localEnabled: false
            ),
            .remote
        )

        settings.predictiveEchoLocalEnabled = true
        XCTAssertTrue(defaults.bool(forKey: "predictiveEchoLocalEnabled"))
        XCTAssertEqual(
            TerminalPool.enabledPredictiveEchoLocation(
                herdLocation: .local,
                localEnabled: settings.predictiveEchoLocalEnabled
            ),
            .local
        )
    }
}
