import Foundation
import Security
import XCTest
@testable import RaiApp

final class APNsKeyReadTests: XCTestCase {
    private static let pem = """
    -----BEGIN PRIVATE KEY-----
    MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgevZzL1gdAFr88hb2
    OF/2NxApJCzGCEDdfSp6VQO30hyhRANCAAQRWz+jn65BtOMvdyHKcvjBeBSDZH2r
    1RTwjmYSi9R/zpBnuQ4EiMnCqfMPWiZqB4QdbAd0E7oH50VpuZ1P087G
    -----END PRIVATE KEY-----
    """

    private func makeDefaults() -> UserDefaults {
        let suite = "apns-key-read-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "apns.hasKey")
        return defaults
    }

    @MainActor
    func testFailedReadIsNotCachedAndRetries() {
        var attempts = 0
        let settings = APNsSettings(defaults: makeDefaults()) {
            attempts += 1
            return attempts == 1 ? ("", errSecAuthFailed) : (Self.pem, errSecSuccess)
        }

        XCTAssertEqual(settings.keyP8, "")
        XCTAssertEqual(settings.lastKeyReadStatus, errSecAuthFailed)
        XCTAssertNotNil(settings.keyProblem)
        XCTAssertTrue(settings.keyProblem?.contains("OSStatus \(errSecAuthFailed)") == true)

        // The next read retries and the success is cached.
        XCTAssertEqual(settings.keyP8, Self.pem)
        XCTAssertNil(settings.keyProblem)
        XCTAssertEqual(settings.keyP8, Self.pem)
        XCTAssertEqual(attempts, 2)
    }

    func testEmptyKeyIsNamedNotAnASN1Error() {
        let configuration = APNsConfiguration(teamID: "T", keyID: "K", keyP8: "", bundleID: "b", defaultEnvironment: "sandbox")
        XCTAssertThrowsError(try APNsProviderJWT.make(configuration: configuration)) { error in
            XCTAssertEqual(error as? APNsKeyError, .missing)
            XCTAssertTrue(error.localizedDescription.contains("Keychain"))
        }
    }
}
