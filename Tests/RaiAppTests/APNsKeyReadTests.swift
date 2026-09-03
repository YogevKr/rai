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
            // Two failures (the first read, and keyProblem's own retry), then
            // the Keychain answers.
            return attempts <= 2 ? ("", errSecAuthFailed) : (Self.pem, errSecSuccess)
        }

        XCTAssertEqual(settings.keyP8, "")
        XCTAssertEqual(settings.lastKeyReadStatus, errSecAuthFailed)
        let problem = settings.keyProblem
        XCTAssertNotNil(problem)
        XCTAssertTrue(problem?.contains("OSStatus \(errSecAuthFailed)") == true, problem ?? "nil")

        // The next read retries and the success is cached.
        XCTAssertEqual(settings.keyP8, Self.pem)
        XCTAssertNil(settings.keyProblem)
        XCTAssertEqual(settings.keyP8, Self.pem)
        XCTAssertEqual(attempts, 3)
    }

    func testEmptyKeyIsNamedNotAnASN1Error() {
        let configuration = APNsConfiguration(teamID: "T", keyID: "K", bundleID: "b", keyP8: "", defaultEnvironment: "sandbox")
        XCTAssertThrowsError(try APNsProviderJWT.make(configuration: configuration)) { error in
            XCTAssertEqual(error as? APNsKeyError, .missing)
            XCTAssertTrue(error.localizedDescription.contains("Keychain"))
        }
    }

    func testParserAcceptsPastedKeyShapes() throws {
        let clean = try APNsKeyParser.privateKey(from: Self.pem)
        let crlf = try APNsKeyParser.privateKey(from: Self.pem.replacingOccurrences(of: "\n", with: "\r\n"))
        let quoted = try APNsKeyParser.privateKey(from: "\"" + Self.pem + "\"\n")
        let oneLine = try APNsKeyParser.privateKey(from: Self.pem.replacingOccurrences(of: "\n", with: ""))
        let bodyOnly = try APNsKeyParser.privateKey(from: Self.pem
            .components(separatedBy: "\n").filter { !$0.contains("-----") }.joined(separator: "\n"))
        for key in [crlf, quoted, oneLine, bodyOnly] {
            XCTAssertEqual(key.rawRepresentation, clean.rawRepresentation)
        }
        XCTAssertThrowsError(try APNsKeyParser.privateKey(from: "not a key"))
    }
}
