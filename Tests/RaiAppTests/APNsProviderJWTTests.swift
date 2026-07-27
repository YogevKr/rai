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
