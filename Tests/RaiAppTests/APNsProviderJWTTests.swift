import CryptoKit
@testable import RaiApp
import XCTest

final class APNsProviderJWTTests: XCTestCase {
    func testJWTClaimsAndSignature() throws {
        let privateKey = P256.Signing.PrivateKey()
        let issuedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let configuration = APNsConfiguration(
            teamID: "TEAM123",
            keyID: "KEY456",
            bundleID: "gr.krig.rai.ios",
            keyP8: privateKey.pemRepresentation,
            defaultEnvironment: "sandbox"
        )

        let jwt = try APNsProviderJWT.make(configuration: configuration, issuedAt: issuedAt)
        let parts = jwt.split(separator: ".")
        XCTAssertEqual(parts.count, 3)

        let header = try XCTUnwrap(decodeJSON(String(parts[0])))
        XCTAssertEqual(header["alg"] as? String, "ES256")
        XCTAssertEqual(header["kid"] as? String, "KEY456")
        let claims = try XCTUnwrap(decodeJSON(String(parts[1])))
        XCTAssertEqual(claims["iss"] as? String, "TEAM123")
        XCTAssertEqual(claims["iat"] as? Int, 1_750_000_000)

        let signatureData = try XCTUnwrap(base64URLDecode(String(parts[2])))
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureData)
        XCTAssertTrue(privateKey.publicKey.isValidSignature(
            signature,
            for: Data("\(parts[0]).\(parts[1])".utf8)
        ))
    }

    private func decodeJSON(_ value: String) -> [String: Any]? {
        guard let data = base64URLDecode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func base64URLDecode(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

final class APNsDeliveryQueueTests: XCTestCase {
    func testSerializesMatchingDeliveryKeys() async {
        let queue = APNsDeliveryQueue<Int>()
        let values = RecordedValues()
        let firstStarted = expectation(description: "first delivery started")

        let first = Task {
            await queue.enqueue(key: "pane:device") {
                firstStarted.fulfill()
                try? await Task.sleep(for: .milliseconds(100))
                await values.append(1)
                return 1
            }
        }
        await fulfillment(of: [firstStarted], timeout: 1)
        let second = Task {
            await queue.enqueue(key: "pane:device") {
                await values.append(2)
                return 2
            }
        }

        _ = await (first.value, second.value)

        let recorded = await values.all()
        XCTAssertEqual(recorded, [1, 2])
    }

    func testStalledDeviceDoesNotDelayAnotherDevice() async {
        let queue = APNsDeliveryQueue<Int>()
        let gate = AsyncGate()
        let stalledStarted = expectation(description: "stalled device started")
        let healthyDelivered = expectation(description: "healthy device delivered")

        let stalled = Task {
            await queue.enqueue(key: "pane:stalled-device") {
                stalledStarted.fulfill()
                await gate.wait()
                return 1
            }
        }
        await fulfillment(of: [stalledStarted], timeout: 1)

        let healthy = Task {
            await queue.enqueue(key: "pane:healthy-device") {
                healthyDelivered.fulfill()
                return 2
            }
        }
        await fulfillment(of: [healthyDelivered], timeout: 1)

        await gate.open()
        _ = await (stalled.value, healthy.value)
    }
}

final class PushBadgeCounterTests: XCTestCase {
    func testCountsEachCollapseKeyOnceUntilReset() {
        var counter = PushBadgeCounter()

        XCTAssertEqual(counter.badge(for: "connection:pane-1"), 1)
        XCTAssertEqual(counter.badge(for: "connection:pane-1"), 1)
        XCTAssertEqual(counter.badge(for: "connection:pane-2"), 2)

        counter.reset()
        XCTAssertEqual(counter.badge(for: "connection:pane-1"), 1)
    }
}

private actor RecordedValues {
    private var values: [Int] = []

    func append(_ value: Int) {
        values.append(value)
    }

    func all() -> [Int] {
        values
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
