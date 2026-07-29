import CryptoKit
import Foundation

struct APNsProviderJWT {
    static func make(
        configuration: APNsConfiguration,
        issuedAt: Date = Date()
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let header = try encoder.encode(Header(alg: "ES256", kid: configuration.keyID))
        let claims = try encoder.encode(Claims(
            iss: configuration.teamID,
            iat: Int(issuedAt.timeIntervalSince1970)
        ))
        let signingInput = "\(header.base64URLEncoded()).\(claims.base64URLEncoded())"
        let key = try P256.Signing.PrivateKey(pemRepresentation: configuration.keyP8)
        let signature = try key.signature(for: Data(signingInput.utf8))
        return "\(signingInput).\(signature.rawRepresentation.base64URLEncoded())"
    }

    private struct Header: Encodable {
        let alg: String
        let kid: String
    }

    private struct Claims: Encodable {
        let iss: String
        let iat: Int
    }
}

actor APNsPusher {
    enum Result: Equatable {
        case delivered
        case deadToken
        case failed
    }

    private struct CachedJWT {
        let value: String
        let createdAt: Date
        let credentials: String
    }

    private struct ResponseBody: Decodable {
        let reason: String?
    }

    private struct Payload: Encodable {
        struct APS: Encodable {
            struct Alert: Encodable {
                let title: String
                let subtitle: String?
                let body: String
            }

            let alert: Alert
            let sound: String
            let category: String?
            let badge: Int?
        }

        let aps: APS
        let paneID: String
        let workspaceID: String
        let workspace: String?
    }

    private var cachedJWT: CachedJWT?
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(
        configuration: APNsConfiguration,
        deviceToken: String,
        environment: String,
        title: String,
        subtitle: String?,
        body: String,
        paneID: String,
        workspaceID: String,
        workspace: String?,
        category: String?,
        badge: Int? = nil
    ) async -> Result {
        do {
            let jwt = try providerJWT(for: configuration)
            let host = environment == "production"
                ? "api.push.apple.com"
                : "api.sandbox.push.apple.com"
            guard let url = URL(string: "https://\(host)/3/device/\(deviceToken)") else {
                return .failed
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
            request.setValue(configuration.bundleID, forHTTPHeaderField: "apns-topic")
            request.setValue("alert", forHTTPHeaderField: "apns-push-type")
            request.setValue("10", forHTTPHeaderField: "apns-priority")
            request.setValue("0", forHTTPHeaderField: "apns-expiration")
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try JSONEncoder().encode(Payload(
                aps: .init(
                    alert: .init(title: title, subtitle: subtitle, body: body),
                    sound: "default",
                    category: category,
                    badge: badge
                ),
                paneID: paneID,
                workspaceID: workspaceID,
                workspace: workspace
            ))

            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                NSLog("rai: APNs returned a non-HTTP response")
                return .failed
            }
            if response.statusCode == 200 {
                return .delivered
            }
            let reason = try? JSONDecoder().decode(ResponseBody.self, from: data).reason
            if response.statusCode == 410
                || (response.statusCode == 400
                    && (reason == "BadDeviceToken"
                        || reason == "DeviceTokenNotForTopic"
                        || reason == "Unregistered")) {
                return .deadToken
            }
            NSLog("rai: APNs request failed (%d): %@", response.statusCode, reason ?? "unknown")
            return .failed
        } catch {
            NSLog("rai: APNs request failed: %@", error.localizedDescription)
            return .failed
        }
    }

    private func providerJWT(for configuration: APNsConfiguration) throws -> String {
        let now = Date()
        let credentials = "\(configuration.teamID):\(configuration.keyID):\(configuration.keyP8)"
        if let cachedJWT,
           cachedJWT.credentials == credentials,
           now.timeIntervalSince(cachedJWT.createdAt) < 50 * 60 {
            return cachedJWT.value
        }
        let value = try APNsProviderJWT.make(configuration: configuration, issuedAt: now)
        cachedJWT = CachedJWT(value: value, createdAt: now, credentials: credentials)
        return value
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
