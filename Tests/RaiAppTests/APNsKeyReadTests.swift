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

    private func fixture() throws -> (UserDefaults, URL) {
        let suite = "apns-key-file-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        return (defaults, root.appendingPathComponent("Rai/apns-key.p8"))
    }

    @MainActor
    func testSaveWritesNormalizedKeyWithOwnerOnlyPermissions() throws {
        let (defaults, keyURL) = try fixture()
        let settings = APNsSettings(
            defaults: defaults,
            keyFileURL: keyURL,
            keyReader: { ("", errSecItemNotFound) }
        )

        try settings.setKeyP8(Self.pem.replacingOccurrences(of: "\n", with: ""))

        XCTAssertEqual(settings.keyReadState, .readable)
        XCTAssertTrue(settings.keyP8.contains("-----BEGIN PRIVATE KEY-----"))
        XCTAssertEqual(permissions(at: keyURL), 0o600)
        XCTAssertEqual(permissions(at: keyURL.deletingLastPathComponent()), 0o700)
    }

    @MainActor
    func testMissingLegacyItemLeavesFileMissing() throws {
        let (defaults, keyURL) = try fixture()
        var reads = 0

        let settings = APNsSettings(
            defaults: defaults, keyFileURL: keyURL, migrateImmediately: true
        ) {
            reads += 1
            return ("", errSecItemNotFound)
        }

        XCTAssertEqual(settings.keyReadState, .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyURL.path))
        XCTAssertEqual(reads, 1)

        _ = APNsSettings(defaults: defaults, keyFileURL: keyURL, migrateImmediately: true) {
            reads += 1
            return (Self.pem, errSecSuccess)
        }
        XCTAssertEqual(reads, 1, "Migration must run only once")
    }

    @MainActor
    func testValidLegacyItemMigratesOnce() throws {
        let (defaults, keyURL) = try fixture()
        var reads = 0

        let settings = APNsSettings(
            defaults: defaults, keyFileURL: keyURL, migrateImmediately: true
        ) {
            reads += 1
            return (Self.pem, errSecSuccess)
        }

        XCTAssertEqual(settings.keyReadState, .readable)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(permissions(at: keyURL), 0o600)

        _ = APNsSettings(defaults: defaults, keyFileURL: keyURL, migrateImmediately: true) {
            reads += 1
            return ("not a key", errSecSuccess)
        }
        XCTAssertEqual(reads, 1)
    }

    @MainActor
    func testInvalidLegacyItemSurfacesPasteAgainFix() throws {
        let (defaults, keyURL) = try fixture()

        let settings = APNsSettings(
            defaults: defaults, keyFileURL: keyURL, migrateImmediately: true
        ) {
            ("not a key", errSecSuccess)
        }

        XCTAssertEqual(settings.keyReadState, .unreadable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyURL.path))
        XCTAssertTrue(settings.keyProblem?.contains("Paste the key again") == true)
    }

    @MainActor
    func testTemporaryLegacyReadFailureRetriesOnNextLaunch() throws {
        let (defaults, keyURL) = try fixture()
        var reads = 0

        let first = APNsSettings(
            defaults: defaults, keyFileURL: keyURL, migrateImmediately: true
        ) {
            reads += 1
            return ("", errSecInteractionNotAllowed)
        }
        XCTAssertEqual(first.keyReadState, .unreadable)

        let second = APNsSettings(
            defaults: defaults, keyFileURL: keyURL, migrateImmediately: true
        ) {
            reads += 1
            return (Self.pem, errSecSuccess)
        }
        XCTAssertEqual(second.keyReadState, .readable)
        XCTAssertEqual(reads, 2)
    }

    @MainActor
    func testPriorReleaseUnreadableMigrationRetries() throws {
        let (defaults, keyURL) = try fixture()
        defaults.set(true, forKey: "apns.keyFileMigrationAttempted")
        defaults.set("unreadable", forKey: "apns.keyFileMigrationProblem")

        let settings = APNsSettings(
            defaults: defaults, keyFileURL: keyURL, migrateImmediately: true
        ) {
            (Self.pem, errSecSuccess)
        }

        XCTAssertEqual(settings.keyReadState, .readable)
        XCTAssertNil(settings.keyProblem)
    }

    @MainActor
    func testMissingLegacyItemClearsTemporaryReadFailure() throws {
        let (defaults, keyURL) = try fixture()

        let first = APNsSettings(
            defaults: defaults, keyFileURL: keyURL, migrateImmediately: true
        ) {
            ("", errSecInteractionNotAllowed)
        }
        XCTAssertEqual(first.keyReadState, .unreadable)

        let second = APNsSettings(
            defaults: defaults, keyFileURL: keyURL, migrateImmediately: true
        ) {
            ("", errSecItemNotFound)
        }
        XCTAssertEqual(second.keyReadState, .missing)
        XCTAssertEqual(
            second.keyProblem,
            "No APNs key file exists. Paste the .p8 in Settings → iPhone."
        )
    }

    @MainActor
    func testTemporaryFileWriteFailureRetriesOnNextLaunch() throws {
        let (defaults, keyURL) = try fixture()
        let blockedDirectory = keyURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: blockedDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("blocked".utf8).write(to: blockedDirectory)

        let first = APNsSettings(
            defaults: defaults, keyFileURL: keyURL, migrateImmediately: true
        ) {
            (Self.pem, errSecSuccess)
        }
        XCTAssertEqual(first.keyReadState, .unreadable)

        try FileManager.default.removeItem(at: blockedDirectory)
        let second = APNsSettings(
            defaults: defaults, keyFileURL: keyURL, migrateImmediately: true
        ) {
            (Self.pem, errSecSuccess)
        }
        XCTAssertEqual(second.keyReadState, .readable)
    }

    @MainActor
    func testSaveRefusesInvalidKeyAndNamesTheReason() throws {
        let (defaults, keyURL) = try fixture()
        let settings = APNsSettings(
            defaults: defaults,
            keyFileURL: keyURL,
            keyReader: { ("", errSecItemNotFound) }
        )

        XCTAssertThrowsError(try settings.setKeyP8("not a key")) { error in
            XCTAssertTrue(error.localizedDescription.contains("not a valid .p8 PEM"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyURL.path))
    }

    func testEmptyKeyIsNamedNotAnASN1Error() {
        let configuration = APNsConfiguration(
            teamID: "T", keyID: "K", bundleID: "b", keyP8: "",
            defaultEnvironment: "sandbox"
        )
        XCTAssertThrowsError(try APNsProviderJWT.make(configuration: configuration)) { error in
            XCTAssertEqual(error as? APNsKeyError, .missing)
            XCTAssertTrue(error.localizedDescription.contains("key file"))
        }
    }

    func testParserAcceptsPastedKeyShapes() throws {
        let clean = try APNsKeyParser.privateKey(from: Self.pem)
        let crlf = try APNsKeyParser.privateKey(
            from: Self.pem.replacingOccurrences(of: "\n", with: "\r\n")
        )
        let quoted = try APNsKeyParser.privateKey(from: "\"" + Self.pem + "\"\n")
        let oneLine = try APNsKeyParser.privateKey(
            from: Self.pem.replacingOccurrences(of: "\n", with: "")
        )
        let bodyOnly = try APNsKeyParser.privateKey(from: Self.pem
            .components(separatedBy: "\n")
            .filter { !$0.contains("-----") }
            .joined(separator: "\n"))
        let hexEncoded = try APNsKeyParser.privateKey(
            from: Data(Self.pem.utf8).map { String(format: "%02x", $0) }.joined()
        )
        for key in [crlf, quoted, oneLine, bodyOnly, hexEncoded] {
            XCTAssertEqual(key.rawRepresentation, clean.rawRepresentation)
        }
        XCTAssertThrowsError(try APNsKeyParser.privateKey(from: "not a key"))
    }

    private func permissions(at url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
