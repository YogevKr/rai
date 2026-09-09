import AppKit
import Foundation
import RaiCore
import Security
import XCTest

@testable import RaiApp

@MainActor
final class PushRegistrationTests: XCTestCase {
    func testRegistrationPreservesVariableLengthTokensAndRejectsInvalidBytes() throws {
        _ = NSApplication.shared
        let defaultsName = "PushRegistrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        addTeardownBlock { defaults.removePersistentDomain(forName: defaultsName) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rai-push-registration-tests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let model = RaiModel(
            client: HerdrClient(socketPath: "/nonexistent/herdr.sock"),
            userDefaults: defaults
        )
        let server = RaiBridgeServer(
            model: model,
            userDefaults: defaults,
            apnsSettings: APNsSettings(
                defaults: defaults,
                keyFileURL: directory.appendingPathComponent("apns-key.p8"),
                keyReader: { ("", errSecItemNotFound) }
            ),
            auditLogURL: directory.appendingPathComponent("audit.jsonl")
        )
        var expectedTokens = Set<String>()
        for byteCount in [1, 32, 80, 128] {
            let token = String(repeating: "Ab", count: byteCount)
            XCTAssertNil(server.registerPush(
                deviceToken: token,
                environment: "sandbox",
                deviceID: "test-device",
                supportsPermissionDecisions: true,
                supportsScopedNotifications: true
            ))
            expectedTokens.insert(token.lowercased())
            let saved = try XCTUnwrap(defaults.data(forKey: "companionBridgePushRegistrations"))
            let registrations = try JSONDecoder().decode(Set<PushRegistration>.self, from: saved)
            XCTAssertEqual(Set(registrations.map(\.deviceToken)), expectedTokens)
            XCTAssertEqual(server.registeredPushDeviceCount, expectedTokens.count)
            XCTAssertTrue(registrations.allSatisfy {
                $0.deviceID == "test-device" && $0.environment == "sandbox"
                    && $0.supportsPermissionDecisions && $0.supportsScopedNotifications
            })
        }

        let saved = try XCTUnwrap(defaults.data(forKey: "companionBridgePushRegistrations"))
        for token in ["", "a", "abc", "gg", "ab cd", "ab\n", "ＡＢ", "١٢"] {
            let response = server.registerPush(
                deviceToken: token,
                environment: "sandbox",
                deviceID: "test-device",
                supportsPermissionDecisions: false,
                supportsScopedNotifications: false
            )
            guard case let .error(_, code, _, _, _) = response else {
                XCTFail("Invalid token must return a bridge error")
                continue
            }
            XCTAssertEqual(code, .invalidRequest)
            XCTAssertEqual(defaults.data(forKey: "companionBridgePushRegistrations"), saved)
            XCTAssertEqual(server.registeredPushDeviceCount, expectedTokens.count)
        }
        let response = server.registerPush(
            deviceToken: String(repeating: "ab", count: 80),
            environment: "invalid",
            deviceID: "test-device",
            supportsPermissionDecisions: true,
            supportsScopedNotifications: true
        )
        guard case let .error(_, code, _, _, _) = response else {
            return XCTFail("Invalid environment must return a bridge error")
        }
        XCTAssertEqual(code, .invalidRequest)
        XCTAssertEqual(defaults.data(forKey: "companionBridgePushRegistrations"), saved)
    }
}
