import AppKit
import Foundation
import RaiCore
import XCTest

@testable import RaiApp

final class BridgeCredentialTests: XCTestCase {
    func testPairingCodeExpiresAfterTenMinutes() throws {
        var current = Date(timeIntervalSince1970: 1_000)
        let defaults = makeDefaults()
        let store = BridgeDeviceCredentialStore(
            defaults: defaults,
            now: { current },
            randomBytes: deterministicBytes
        )

        let code = try XCTUnwrap(store.pairingCode)
        XCTAssertEqual(code.value.count, 8)
        XCTAssertTrue(code.value.allSatisfy(BridgeDeviceCredentialStore.codeAlphabet.contains))
        XCTAssertEqual(code.expiresAt, current.addingTimeInterval(600))
        current.addTimeInterval(601)
        XCTAssertNil(store.validPairingCode())
    }

    func testFiveFailedAttemptsInvalidatePairingCode() throws {
        let store = BridgeDeviceCredentialStore(
            defaults: makeDefaults(),
            randomBytes: deterministicBytes
        )
        for attempt in 1...5 {
            XCTAssertEqual(
                store.exchange(code: "ZZZZZZZZ", client: client).failure,
                .invalidOrExpired
            )
            if attempt < 5 {
                XCTAssertEqual(store.pairingCode?.failedAttempts, attempt)
            }
        }
        XCTAssertNil(store.pairingCode)
    }

    func testSpentPairingCodeCannotBeReplayed() throws {
        let store = BridgeDeviceCredentialStore(
            defaults: makeDefaults(),
            randomBytes: deterministicBytes
        )
        let code = try XCTUnwrap(store.pairingCode?.value)
        let result = try XCTUnwrap(store.exchange(code: code, client: client).success)
        XCTAssertNotNil(store.pairingCode)
        XCTAssertNotNil(store.authenticate(token: result.token))
        XCTAssertNil(store.pairingCode)
        XCTAssertEqual(store.exchange(code: code, client: client).failure, .invalidOrExpired)
        XCTAssertEqual(store.devices.count, 1)
    }

    func testTokenHashVerificationUsesNoPlaintextAtRest() throws {
        let defaults = makeDefaults()
        let store = BridgeDeviceCredentialStore(
            defaults: defaults,
            randomBytes: deterministicBytes
        )
        let code = try XCTUnwrap(store.pairingCode?.value)
        let result = try XCTUnwrap(store.exchange(code: code, client: client).success)

        XCTAssertEqual(store.authenticate(token: result.token)?.id, result.device.id)
        XCTAssertNil(store.authenticate(token: result.token + "x"))
        XCTAssertEqual(store.devices[0].tokenHash, BridgeDeviceCredentialStore.hash(result.token))
        XCTAssertFalse(String(data: try XCTUnwrap(defaults.data(forKey: "companionBridgePairedDevicesV1")), encoding: .utf8)?.contains(result.token) == true)
        XCTAssertTrue(
            BridgeDeviceCredentialStore.constantTimeEqual(
                store.devices[0].tokenHash,
                BridgeDeviceCredentialStore.hash(result.token)
            )
        )
        XCTAssertFalse(
            BridgeDeviceCredentialStore.constantTimeEqual(Data([1]), Data([1, 0]))
        )
        let restoredStore = BridgeDeviceCredentialStore(
            defaults: defaults,
            randomBytes: deterministicBytes,
            mintInitialCode: false
        )
        XCTAssertEqual(restoredStore.authenticate(token: result.token)?.id, result.device.id)
    }

    func testPushPreferencesPersistPerPairedDevice() throws {
        let defaults = makeDefaults()
        let store = BridgeDeviceCredentialStore(
            defaults: defaults,
            randomBytes: deterministicBytes
        )
        let code = try XCTUnwrap(store.pairingCode?.value)
        let result = try XCTUnwrap(store.exchange(code: code, client: client).success)
        let device = try XCTUnwrap(store.authenticate(token: result.token))
        let preferences = PushPreferences(
            kinds: .init(needsYou: false, finished: true),
            snoozeUntil: Date(timeIntervalSinceReferenceDate: 2_000),
            dnd: .init(start: 22 * 60, end: 8 * 60)
        )

        XCTAssertEqual(
            store.updatePushPreferences(preferences, deviceID: device.id)?.pushPreferences,
            preferences
        )
        let restored = BridgeDeviceCredentialStore(
            defaults: defaults,
            randomBytes: deterministicBytes,
            mintInitialCode: false
        )
        XCTAssertEqual(restored.devices.first?.pushPreferences, preferences)
    }

    func testLegacyPairedDeviceDefaultsNotificationPreferences() throws {
        struct LegacyDevice: Encodable {
            let id: String
            let label: String
            let tokenHash: Data
            let createdAt: Date
            let lastSeen: Date
        }
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        let data = try JSONEncoder().encode(LegacyDevice(
            id: "phone-1",
            label: "Phone",
            tokenHash: Data([1, 2, 3]),
            createdAt: date,
            lastSeen: date
        ))

        let device = try JSONDecoder().decode(BridgePairedDevice.self, from: data)

        XCTAssertEqual(device.pushPreferences, .default)
    }

    func testPairingDoesNotTrustClientIdentifierAsCredentialIdentity() throws {
        let store = BridgeDeviceCredentialStore(
            defaults: makeDefaults(),
            randomBytes: deterministicBytes
        )
        let firstCode = try XCTUnwrap(store.pairingCode?.value)
        let first = try XCTUnwrap(store.exchange(code: firstCode, client: client).success)
        XCTAssertNotNil(store.authenticate(token: first.token))
        let secondCode = try XCTUnwrap(store.regeneratePairingCode()?.value)
        let second = try XCTUnwrap(store.exchange(code: secondCode, client: client).success)
        XCTAssertNotNil(store.authenticate(token: second.token))

        XCTAssertNotEqual(first.device.id, second.device.id)
        XCTAssertEqual(store.devices.count, 2)
        XCTAssertNotNil(store.authenticate(token: first.token))
        XCTAssertNotNil(store.authenticate(token: second.token))
    }

    func testLostPairingReplyCanRetryUntilLatestTokenConfirms() throws {
        var call = 0
        let store = BridgeDeviceCredentialStore(
            defaults: makeDefaults(),
            randomBytes: { count in
                defer { call += 1 }
                return [UInt8](repeating: UInt8(call & 0xff), count: count)
            }
        )
        let code = try XCTUnwrap(store.pairingCode?.value)
        let first = try XCTUnwrap(store.exchange(code: code, client: client).success)
        let retry = try XCTUnwrap(store.exchange(code: code, client: client).success)

        XCTAssertNotEqual(first.token, retry.token)
        XCTAssertTrue(store.devices.isEmpty)
        XCTAssertNil(store.authenticate(token: first.token))
        XCTAssertEqual(store.authenticate(token: retry.token)?.id, retry.device.id)
        XCTAssertNil(store.pairingCode)
        XCTAssertEqual(store.devices.count, 1)
    }

    func testPendingCredentialCannotConfirmAfterCodeExpiry() throws {
        var current = Date(timeIntervalSince1970: 1_000)
        let store = BridgeDeviceCredentialStore(
            defaults: makeDefaults(),
            now: { current },
            randomBytes: deterministicBytes
        )
        let code = try XCTUnwrap(store.pairingCode?.value)
        let result = try XCTUnwrap(store.exchange(code: code, client: client).success)

        current.addTimeInterval(601)

        XCTAssertNil(store.authenticate(token: result.token))
        XCTAssertNil(store.pairingCode)
        XCTAssertTrue(store.devices.isEmpty)
    }

    @MainActor
    func testServerMigrationDeletesLegacySharedToken() {
        _ = NSApplication.shared
        let defaults = makeDefaults()
        defaults.set("legacy-token", forKey: "companionBridgePairingToken")
        defaults.set(false, forKey: "apns.hasKey")
        let auditURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rai-bridge-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("bridge-audit.jsonl")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: auditURL.deletingLastPathComponent())
        }
        let model = RaiModel(
            client: HerdrClient(socketPath: "/nonexistent/herdr.sock"),
            userDefaults: defaults
        )

        _ = RaiBridgeServer(
            model: model,
            userDefaults: defaults,
            apnsSettings: APNsSettings(defaults: defaults),
            auditLogURL: auditURL
        )

        XCTAssertNil(defaults.object(forKey: "companionBridgePairingToken"))
    }

    @MainActor
    func testRevokeRejectsNextHelloAndDropsLiveConnections() throws {
        let store = BridgeDeviceCredentialStore(
            defaults: makeDefaults(),
            randomBytes: deterministicBytes
        )
        let code = try XCTUnwrap(store.pairingCode?.value)
        let result = try XCTUnwrap(store.exchange(code: code, client: client).success)
        XCTAssertNotNil(store.authenticate(token: result.token))
        let registry = BridgeLiveConnectionRegistry()
        let connection = NSObject()
        let id = ObjectIdentifier(connection)
        var revoked = false
        registry.register(id: id, deviceID: result.device.id) { revoked = true }

        XCTAssertTrue(store.revoke(deviceID: result.device.id))
        XCTAssertEqual(registry.revoke(deviceID: result.device.id), [id])
        XCTAssertTrue(revoked)
        XCTAssertEqual(registry.connectedDeviceCount, 0)
        XCTAssertNil(store.authenticate(token: result.token))
    }

    private var client: ClientInfo {
        ClientInfo(
            deviceID: "phone-1",
            name: "Test Phone",
            platform: "iOS",
            model: "iPhone 16"
        )
    }

    private func makeDefaults() -> UserDefaults {
        let name = "BridgeCredentialTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func deterministicBytes(_ count: Int) throws -> [UInt8] {
        Array((0..<count).map { UInt8($0 & 31) })
    }
}

final class BridgeAuditTests: XCTestCase {
    func testPushPreferencesCreateAnAuditEvent() throws {
        let event = try XCTUnwrap(BridgeAuditEvent(.pushPrefs(.default)))

        XCTAssertEqual(event.action, "pushPrefs")
        XCTAssertEqual(event.content, .none)
    }

    func testAuditLineShapeBoundsTextAndRedactsCredentials() async throws {
        let directory = temporaryDirectory()
        let url = directory.appendingPathComponent("bridge-audit.jsonl")
        let date = Date(timeIntervalSince1970: 1_000)
        let logger = try BridgeAuditLogger(fileURL: url, now: { date })
        let longText = String(repeating: "x", count: 250) + "\r"
        let input = try XCTUnwrap(
            BridgeAuditEvent(
                .input(
                    paneID: "pane-1",
                    bytesBase64: Data(longText.utf8).base64EncodedString()
                )
            )
        )
        XCTAssertTrue(
            logger.enqueue(deviceID: "device-1", deviceLabel: "Test Phone", event: input)
        )
        let pushToken = String(repeating: "a", count: 64)
        XCTAssertTrue(
            logger.enqueue(
                deviceID: "device-1",
                deviceLabel: "Test Phone",
                event: try XCTUnwrap(
                    BridgeAuditEvent(.registerPush(deviceToken: pushToken, environment: "sandbox"))
                )
            )
        )
        let didFlush = await logger.flush()
        XCTAssertTrue(didFlush)

        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0]["ts"] as? String, "1970-01-01T00:16:40Z")
        XCTAssertEqual(lines[0]["device"] as? String, "Test Phone")
        XCTAssertEqual(lines[0]["device_id"] as? String, "device-1")
        XCTAssertEqual(lines[0]["action"] as? String, "input")
        XCTAssertEqual((lines[0]["target_ids"] as? [String: String])?["pane_id"], "pane-1")
        XCTAssertEqual((lines[0]["content"] as? String)?.count, 200)
        XCTAssertTrue(lines[1]["content"] is NSNull)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains(pushToken))
        XCTAssertNil(
            BridgeAuditEvent(
                .pair(
                    code: "23456789",
                    protocolVersion: bridgeProtocolVersion,
                    client: ClientInfo(deviceID: "1", name: "Phone", platform: "iOS")
                )
            )
        )
        XCTAssertNil(
            BridgeAuditEvent(
                .hello(
                    token: String(repeating: "b", count: 43),
                    client: ClientInfo(deviceID: "1", name: "Phone", platform: "iOS")
                )
            )
        )
    }

    func testAuditUsesByteCountForNonPrintableInputAndRotatesAtLimit() async throws {
        let directory = temporaryDirectory()
        let url = directory.appendingPathComponent("bridge-audit.jsonl")
        let logger = try BridgeAuditLogger(fileURL: url, maximumBytes: 120)
        let event = try XCTUnwrap(
            BridgeAuditEvent(
                .input(paneID: "pane-1", bytesBase64: Data([0, 0xFF]).base64EncodedString())
            )
        )
        XCTAssertTrue(logger.enqueue(deviceID: "device-1", deviceLabel: "Phone", event: event))
        XCTAssertTrue(logger.enqueue(deviceID: "device-1", deviceLabel: "Phone", event: event))
        let didFlush = await logger.flush()
        XCTAssertTrue(didFlush)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertEqual(object["content"] as? Int, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".1"))
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        let rotatedPermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path + ".1")[.posixPermissions]
                as? NSNumber
        )
        XCTAssertEqual(rotatedPermissions.intValue & 0o777, 0o600)
    }

    func testAuditPreservesOrderDuringBurst() async throws {
        let directory = temporaryDirectory()
        let url = directory.appendingPathComponent("bridge-audit.jsonl")
        let logger = try BridgeAuditLogger(fileURL: url)

        for index in 0..<100 {
            let event = try XCTUnwrap(
                BridgeAuditEvent(.selectPane(paneID: "pane-\(index)"))
            )
            XCTAssertTrue(
                logger.enqueue(deviceID: "device-1", deviceLabel: "Phone", event: event)
            )
        }

        let didFlush = await logger.flush()
        XCTAssertTrue(didFlush)
        let paneIDs = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map { line -> String in
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                )
                let targets = try XCTUnwrap(object["target_ids"] as? [String: String])
                return try XCTUnwrap(targets["pane_id"])
            }
        XCTAssertEqual(paneIDs, (0..<100).map { "pane-\($0)" })
    }

    func testFailedFlushClosesAuditGate() async throws {
        let writer = BlockingFailureAuditWriter()
        let logger = BridgeAuditLogger(
            fileURL: URL(fileURLWithPath: "/unused/bridge-audit.jsonl"),
            writeOperation: { data in try writer.write(data) }
        )
        let event = try XCTUnwrap(BridgeAuditEvent(.selectPane(paneID: "pane-1")))

        XCTAssertTrue(logger.enqueue(deviceID: "device-1", deviceLabel: "Phone", event: event))
        let firstFlush = await logger.flush()
        XCTAssertTrue(firstFlush)
        XCTAssertTrue(logger.enqueue(deviceID: "device-1", deviceLabel: "Phone", event: event))
        XCTAssertEqual(writer.failureStarted.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(logger.enqueue(deviceID: "device-1", deviceLabel: "Phone", event: event))
        writer.releaseFailure.signal()
        let failedFlush = await logger.flush()
        XCTAssertFalse(failedFlush)

        XCTAssertFalse(logger.isHealthy)
        XCTAssertFalse(logger.enqueue(deviceID: "device-1", deviceLabel: "Phone", event: event))
        XCTAssertEqual(writer.writeCount, 3)
    }

    func testAuditBacklogRejectsWorkPastItsBound() async throws {
        let writer = BlockingFirstAuditWriter()
        let logger = BridgeAuditLogger(
            fileURL: URL(fileURLWithPath: "/unused/bridge-audit.jsonl"),
            maximumPendingWrites: 2,
            writeOperation: { data in writer.write(data) }
        )
        let event = try XCTUnwrap(BridgeAuditEvent(.selectPane(paneID: "pane-1")))

        XCTAssertTrue(logger.enqueue(deviceID: "device-1", deviceLabel: "Phone", event: event))
        XCTAssertEqual(writer.started.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(logger.enqueue(deviceID: "device-1", deviceLabel: "Phone", event: event))
        XCTAssertFalse(logger.enqueue(deviceID: "device-1", deviceLabel: "Phone", event: event))

        writer.release.signal()
        let didFlush = await logger.flush()
        XCTAssertTrue(didFlush)
        XCTAssertEqual(writer.writeCount, 2)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rai-bridge-tests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private final class BlockingFailureAuditWriter: @unchecked Sendable {
    let failureStarted = DispatchSemaphore(value: 0)
    let releaseFailure = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var writes = 0

    var writeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return writes
    }

    func write(_ data: Data) throws {
        lock.lock()
        writes += 1
        let shouldFail = writes == 2
        lock.unlock()
        if shouldFail {
            failureStarted.signal()
            releaseFailure.wait()
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

private final class BlockingFirstAuditWriter: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var writes = 0

    var writeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return writes
    }

    func write(_ data: Data) {
        lock.lock()
        writes += 1
        let isFirst = writes == 1
        lock.unlock()
        if isFirst {
            started.signal()
            release.wait()
        }
    }
}

private extension Result {
    var success: Success? {
        guard case let .success(value) = self else { return nil }
        return value
    }

    var failure: Failure? {
        guard case let .failure(error) = self else { return nil }
        return error
    }
}
