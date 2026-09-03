import CryptoKit
import Foundation

/// Keeps APNs operations ordered for one device without coupling different devices.
@MainActor
final class APNsDeliveryQueue {
    private struct Delivery {
        let revision: UInt64
        let task: Task<Void, Never>
    }

    private var nextRevision: UInt64 = 0
    private var deliveries: [String: Delivery] = [:]

    func enqueue<Value: Sendable>(
        key: String,
        operation: @escaping @Sendable () async -> Value
    ) -> Task<Value, Never> {
        nextRevision &+= 1
        let revision = nextRevision
        let previous = deliveries[key]?.task
        let valueTask = Task {
            await previous?.value
            return await operation()
        }
        let tail = Task { _ = await valueTask.value }
        deliveries[key] = Delivery(revision: revision, task: tail)

        Task { [weak self] in
            await tail.value
            if self?.deliveries[key]?.revision == revision {
                self?.deliveries[key] = nil
            }
        }
        return valueTask
    }
}

/// Why a push could not be signed, in words the Settings pane can show.
enum APNsKeyError: LocalizedError, Equatable {
    case missing
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .missing:
            return "The APNs key file is empty. Paste the key again."
        case let .invalid(detail):
            return "The stored APNs key is not a valid .p8 PEM (\(detail))."
        }
    }
}

/// Loads the .p8 however it was pasted: a proper PEM, a PEM with CRLF line
/// ends or stray quotes, a single-line PEM, or just the base64 body. CryptoKit's
/// PEM reader is strict about line structure; the DER inside is what matters.
enum APNsKeyParser {
    static func privateKey(from text: String) throws -> P256.Signing.PrivateKey {
        let trimmed = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !trimmed.isEmpty else { throw APNsKeyError.missing }

        // A PEM stored as its hex encoding (one long [0-9a-f] line) is still
        // the same key: decode it and start over.
        if trimmed.count % 2 == 0,
           trimmed.range(of: "^[0-9A-Fa-f]+$", options: .regularExpression) != nil,
           let bytes = Data(hexString: trimmed),
           let text = String(data: bytes, encoding: .utf8),
           text.contains("PRIVATE KEY") {
            return try privateKey(from: text)
        }

        // Body = the text minus the BEGIN/END markers and all whitespace, so a
        // one-line paste works as well as a proper PEM.
        let body = trimmed
            .replacingOccurrences(of: "-----[A-Z ]*-----", with: "", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        if let der = Data(base64Encoded: body), !der.isEmpty {
            if let key = try? P256.Signing.PrivateKey(derRepresentation: der) {
                return key
            }
        }
        do {
            return try P256.Signing.PrivateKey(pemRepresentation: trimmed)
        } catch {
            throw APNsKeyError.invalid(String(describing: error))
        }
    }
}

private extension Data {
    init?(hexString: String) {
        var data = Data(capacity: hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}

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
        let key = try APNsKeyParser.privateKey(from: configuration.keyP8)
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
    struct Result: Equatable, Sendable {
        let status: Int?
        let reason: String

        var isDelivered: Bool { status == 200 }

        var isDeadToken: Bool {
            status == 410
                || (status == 400
                    && ["BadDeviceToken", "DeviceTokenNotForTopic", "Unregistered"]
                        .contains(reason))
        }
    }

    struct RetractionResult: Equatable, Sendable {
        let status: Int?
        let reason: String
        let acceptedNotificationIDs: Set<String>
    }

    private struct CachedJWT {
        let value: String
        let createdAt: Date
        let credentials: String
    }

    private struct ResponseBody: Decodable {
        let reason: String?
    }

    private var cachedJWT: CachedJWT?
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func sendAlert(
        configuration: APNsConfiguration,
        deviceToken: String,
        environment: String,
        title: String,
        subtitle: String?,
        body: String,
        paneID: String?,
        requestID: String? = nil,
        workspaceID: String?,
        workspace: String?,
        category: String?,
        notificationIDs: [String],
        threadID: String,
        summaryArgument: String,
        summaryArgumentCount: Int,
        occurredAt: Date,
        interruptionLevel: APNsInterruptionLevel,
        badge: Int? = nil
    ) async -> Result {
        let payload: Data
        do {
            payload = try APNsPayloadBuilder.alert(
                title: title,
                subtitle: subtitle,
                body: body,
                paneID: paneID,
                requestID: requestID,
                workspaceID: workspaceID,
                workspace: workspace,
                category: category,
                notificationIDs: notificationIDs,
                threadID: threadID,
                summaryArgument: summaryArgument,
                summaryArgumentCount: summaryArgumentCount,
                occurredAt: occurredAt,
                interruptionLevel: interruptionLevel,
                badge: badge
            )
        } catch {
            return Result(status: nil, reason: error.localizedDescription)
        }
        return await send(
            configuration: configuration,
            deviceToken: deviceToken,
            environment: environment,
            pushType: "alert",
            priority: "10",
            expiration: "0",
            payload: payload
        )
    }

    func sendRetraction(
        configuration: APNsConfiguration,
        deviceToken: String,
        environment: String,
        notificationIDs: [String],
        retractedBefore: Date
    ) async -> RetractionResult {
        let batches: [APNsRetractionBatch]
        do {
            batches = try APNsPayloadBuilder.retractionBatchRequests(
                notificationIDs: notificationIDs,
                retractedBefore: retractedBefore
            )
        } catch {
            return RetractionResult(
                status: nil,
                reason: error.localizedDescription,
                acceptedNotificationIDs: []
            )
        }
        var acceptedNotificationIDs: Set<String> = []
        for batch in batches {
            let result = await send(
                configuration: configuration,
                deviceToken: deviceToken,
                environment: environment,
                pushType: "background",
                priority: "5",
                expiration: String(Int(
                    retractedBefore.addingTimeInterval(7 * 24 * 60 * 60).timeIntervalSince1970
                )),
                payload: batch.payload
            )
            guard result.status == 200 else {
                return RetractionResult(
                    status: result.status,
                    reason: result.reason,
                    acceptedNotificationIDs: acceptedNotificationIDs
                )
            }
            acceptedNotificationIDs.formUnion(batch.notificationIDs)
        }
        return RetractionResult(
            status: 200,
            reason: "Success",
            acceptedNotificationIDs: acceptedNotificationIDs
        )
    }

    private func send(
        configuration: APNsConfiguration,
        deviceToken: String,
        environment: String,
        pushType: String,
        priority: String,
        expiration: String,
        payload: Data
    ) async -> Result {
        do {
            let jwt = try providerJWT(for: configuration)
            let host = environment == "production"
                ? "api.push.apple.com"
                : "api.sandbox.push.apple.com"
            guard let url = URL(string: "https://\(host)/3/device/\(deviceToken)") else {
                return Result(status: nil, reason: "Invalid APNs URL")
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
            request.setValue(configuration.bundleID, forHTTPHeaderField: "apns-topic")
            request.setValue(pushType, forHTTPHeaderField: "apns-push-type")
            request.setValue(priority, forHTTPHeaderField: "apns-priority")
            request.setValue(expiration, forHTTPHeaderField: "apns-expiration")
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = payload

            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                return Result(status: nil, reason: "Non-HTTP APNs response")
            }
            if response.statusCode == 200 {
                return Result(status: 200, reason: "Success")
            }
            let reason = try? JSONDecoder().decode(ResponseBody.self, from: data).reason
            let value = reason ?? "Unknown APNs error"
            NSLog("rai: APNs request failed (%d): %@", response.statusCode, value)
            return Result(status: response.statusCode, reason: value)
        } catch {
            NSLog("rai: APNs request failed: %@", error.localizedDescription)
            return Result(status: nil, reason: error.localizedDescription)
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

struct APNsRetractionBatch: Equatable, Sendable {
    let notificationIDs: [String]
    let payload: Data
}

enum APNsInterruptionLevel: String, Encodable, Equatable, Sendable {
    case active
    case timeSensitive = "time-sensitive"
}

enum APNsPayloadBuilder {
    static let maximumPayloadBytes = 4_096

    enum PayloadError: LocalizedError {
        case tooLarge(Int)

        var errorDescription: String? {
            switch self {
            case let .tooLarge(size):
                "APNs payload is \(size) bytes; the limit is \(maximumPayloadBytes)."
            }
        }
    }

    static func alert(
        title: String,
        subtitle: String?,
        body: String,
        paneID: String?,
        requestID: String? = nil,
        workspaceID: String?,
        workspace: String?,
        category: String?,
        notificationIDs: [String],
        threadID: String,
        summaryArgument: String,
        summaryArgumentCount: Int,
        occurredAt: Date,
        interruptionLevel: APNsInterruptionLevel,
        badge: Int?
    ) throws -> Data {
        let title = title.apnsPrefix(maxBytes: 256)
        let subtitle = subtitle?.apnsPrefix(maxBytes: 256)
        let paneID = paneID.flatMap {
            $0.utf8.count <= 512 ? $0 : nil
        }
        let workspaceID = workspaceID.flatMap {
            $0.utf8.count <= 512 ? $0 : nil
        }
        let workspace = workspace?.apnsPrefix(maxBytes: 256)
        let threadID = threadID.apnsPrefix(maxBytes: 256)
        let summaryArgument = summaryArgument.apnsPrefix(maxBytes: 128)

        func payload(body: String) -> AlertPayload {
            AlertPayload(
                aps: .init(
                    alert: .init(
                        title: title,
                        subtitle: subtitle,
                        body: body,
                        summaryArgument: summaryArgument,
                        summaryArgumentCount: summaryArgumentCount
                    ),
                    sound: "default",
                    category: category,
                    badge: badge,
                    threadID: threadID,
                    interruptionLevel: interruptionLevel
                ),
                paneID: paneID,
                requestID: requestID,
                workspaceID: workspaceID,
                workspace: workspace,
                notificationID: notificationIDs.count == 1 ? notificationIDs[0] : nil,
                notificationIDs: notificationIDs,
                notificationTimestamp: occurredAt.timeIntervalSince1970,
                triage: notificationIDs.count > 1 ? true : nil
            )
        }

        let encoder = JSONEncoder()
        let full = try encoder.encode(payload(body: body))
        guard full.count > maximumPayloadBytes else { return full }

        // Keep every stable identifier, then shorten only display copy. This
        // preserves complete retraction data and one APNs request per burst.
        let characters = Array(body)
        var lowerBound = 0
        var upperBound = characters.count
        var best: Data?
        while lowerBound <= upperBound {
            let midpoint = (lowerBound + upperBound) / 2
            let candidateBody = String(characters.prefix(midpoint)) + "…"
            let candidate = try encoder.encode(payload(body: candidateBody))
            if candidate.count <= maximumPayloadBytes {
                best = candidate
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint - 1
            }
        }
        guard let best else { throw PayloadError.tooLarge(full.count) }
        return best
    }

    static func retraction(
        notificationIDs: [String],
        retractedBefore: Date
    ) throws -> Data {
        let data = try JSONEncoder().encode(RetractionPayload(
            aps: .init(contentAvailable: 1),
            retractNotificationIDs: notificationIDs,
            retractedBefore: retractedBefore.timeIntervalSince1970
        ))
        guard data.count <= maximumPayloadBytes else {
            throw PayloadError.tooLarge(data.count)
        }
        return data
    }

    static func retractionBatches(
        notificationIDs: [String],
        retractedBefore: Date
    ) throws -> [Data] {
        try retractionBatchRequests(
            notificationIDs: notificationIDs,
            retractedBefore: retractedBefore
        ).map(\.payload)
    }

    static func retractionBatchRequests(
        notificationIDs: [String],
        retractedBefore: Date
    ) throws -> [APNsRetractionBatch] {
        guard !notificationIDs.isEmpty else { return [] }
        var batches: [APNsRetractionBatch] = []
        var batch: [String] = []
        for identifier in notificationIDs {
            let candidate = batch + [identifier]
            do {
                _ = try retraction(
                    notificationIDs: candidate,
                    retractedBefore: retractedBefore
                )
                batch = candidate
            } catch PayloadError.tooLarge {
                guard !batch.isEmpty else { throw PayloadError.tooLarge(identifier.utf8.count) }
                batches.append(.init(
                    notificationIDs: batch,
                    payload: try retraction(
                        notificationIDs: batch,
                        retractedBefore: retractedBefore
                    )
                ))
                batch = [identifier]
                _ = try retraction(
                    notificationIDs: batch,
                    retractedBefore: retractedBefore
                )
            }
        }
        if !batch.isEmpty {
            batches.append(.init(
                notificationIDs: batch,
                payload: try retraction(
                    notificationIDs: batch,
                    retractedBefore: retractedBefore
                )
            ))
        }
        return batches
    }

    private struct AlertPayload: Encodable {
        struct APS: Encodable {
            struct Alert: Encodable {
                let title: String
                let subtitle: String?
                let body: String
                let summaryArgument: String
                let summaryArgumentCount: Int

                enum CodingKeys: String, CodingKey {
                    case title, subtitle, body
                    case summaryArgument = "summary-arg"
                    case summaryArgumentCount = "summary-arg-count"
                }
            }

            let alert: Alert
            let sound: String
            let category: String?
            let badge: Int?
            let threadID: String
            let interruptionLevel: APNsInterruptionLevel

            enum CodingKeys: String, CodingKey {
                case alert, sound, category, badge
                case threadID = "thread-id"
                case interruptionLevel = "interruption-level"
            }
        }

        let aps: APS
        let paneID: String?
        let requestID: String?
        let workspaceID: String?
        let workspace: String?
        let notificationID: String?
        let notificationIDs: [String]
        let notificationTimestamp: TimeInterval
        let triage: Bool?

        enum CodingKeys: String, CodingKey {
            case aps, paneID, workspaceID, workspace
            case notificationID, notificationIDs, notificationTimestamp, triage
            case requestID = "request_id"
        }
    }

    private struct RetractionPayload: Encodable {
        struct APS: Encodable {
            let contentAvailable: Int

            enum CodingKeys: String, CodingKey {
                case contentAvailable = "content-available"
            }
        }

        let aps: APS
        let retractNotificationIDs: [String]
        let retractedBefore: TimeInterval
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

private extension String {
    func apnsPrefix(maxBytes: Int) -> String {
        guard utf8.count > maxBytes else { return self }
        let suffix = "…"
        let contentLimit = maxBytes - suffix.utf8.count
        var result = ""
        var byteCount = 0
        for character in self {
            let characterBytes = String(character).utf8.count
            guard byteCount + characterBytes <= contentLimit else { break }
            result.append(character)
            byteCount += characterBytes
        }
        return result + suffix
    }
}
