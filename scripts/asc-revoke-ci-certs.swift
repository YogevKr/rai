// Revoke the throwaway signing certificates that CI leaves behind.
//
// `xcodebuild -allowProvisioningUpdates` on a fresh runner mints an
// "Apple Development: Created via API" certificate, and the runner's keychain
// dies with the job. The account fills up and Xcode then fails with
// "Choose a certificate to revoke. Your account has reached the maximum number
// of certificates." (iOS build 37, 2026-09-06). Run this before archiving.
//
// Only certificates whose display name is exactly "Created via API" and whose
// type is a development or App Store distribution type are revoked. Developer
// ID certificates (the Mac release) and anything created by hand are listed
// and left alone. Set DRY_RUN=1 to list without revoking.
//
// Usage: swift scripts/asc-revoke-ci-certs.swift <AuthKey.p8> <key id> <issuer id>

import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    FileHandle.standardError.write(Data("usage: asc-revoke-ci-certs.swift <AuthKey.p8> <key id> <issuer id>\n".utf8))
    exit(2)
}
let keyPath = arguments[1]
let keyID = arguments[2]
let issuerID = arguments[3]
let dryRun = ProcessInfo.processInfo.environment["DRY_RUN"] == "1"
let baseURL = URL(string: ProcessInfo.processInfo.environment["ASC_BASE_URL"] ?? "https://api.appstoreconnect.apple.com")!
let revocableTypes: Set<String> = ["DEVELOPMENT", "IOS_DEVELOPMENT", "DISTRIBUTION", "IOS_DISTRIBUTION"]
let throwawayName = "Created via API"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("::error::\(message)\n".utf8))
    exit(1)
}

func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func makeToken() throws -> String {
    let pem = try String(contentsOfFile: keyPath, encoding: .utf8)
    let key = try P256.Signing.PrivateKey(pemRepresentation: pem)
    let now = Int(Date().timeIntervalSince1970)
    let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID, "typ": "JWT"])
    let claims = try JSONSerialization.data(withJSONObject: [
        "iss": issuerID, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1",
    ])
    let signingInput = base64URL(header) + "." + base64URL(claims)
    let signature = try key.signature(for: Data(signingInput.utf8))
    return signingInput + "." + base64URL(signature.rawRepresentation)
}

struct Certificate {
    let id: String
    let type: String
    let name: String
    let displayName: String
    let expires: String

    var isThrowaway: Bool { revocableTypes.contains(type) && displayName == throwawayName }
}

func request(_ method: String, _ url: URL, token: String) -> (status: Int, body: Data) {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let semaphore = DispatchSemaphore(value: 0)
    var result: (Int, Data) = (0, Data())
    URLSession.shared.dataTask(with: request) { data, response, error in
        if let error { fail("\(method) \(url.path): \(error.localizedDescription)") }
        result = ((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data())
        semaphore.signal()
    }.resume()
    semaphore.wait()
    return result
}

func listCertificates(token: String) -> [Certificate] {
    var certificates: [Certificate] = []
    var next: URL? = baseURL.appendingPathComponent("v1/certificates")
        .appending(queryItems: [URLQueryItem(name: "limit", value: "200")])
    while let url = next {
        let (status, body) = request("GET", url, token: token)
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let items = json["data"] as? [[String: Any]]
        else {
            fail("GET /v1/certificates returned HTTP \(status): \(String(decoding: body.prefix(300), as: UTF8.self))")
        }
        for item in items {
            let attributes = item["attributes"] as? [String: Any] ?? [:]
            certificates.append(Certificate(
                id: item["id"] as? String ?? "",
                type: attributes["certificateType"] as? String ?? "",
                name: attributes["name"] as? String ?? "",
                displayName: attributes["displayName"] as? String ?? "",
                expires: attributes["expirationDate"] as? String ?? ""
            ))
        }
        let links = json["links"] as? [String: Any]
        next = (links?["next"] as? String).flatMap(URL.init(string:))
    }
    return certificates
}

let token: String
do { token = try makeToken() } catch { fail("Cannot sign the App Store Connect token: \(error)") }
let certificates = listCertificates(token: token)
print("Certificates on the account: \(certificates.count)")
for certificate in certificates {
    let verdict = certificate.isThrowaway ? (dryRun ? "would revoke" : "revoke") : "keep"
    print("  \(verdict.padding(toLength: 12, withPad: " ", startingAt: 0)) \(certificate.type) \"\(certificate.name): \(certificate.displayName)\" expires \(certificate.expires) id \(certificate.id)")
}
let throwaways = certificates.filter(\.isThrowaway)
guard !dryRun else { exit(0) }
var revoked = 0
for certificate in throwaways {
    let (status, body) = request("DELETE", baseURL.appendingPathComponent("v1/certificates/\(certificate.id)"), token: token)
    if status == 204 {
        revoked += 1
    } else {
        FileHandle.standardError.write(Data("::warning::Revoking \(certificate.id) returned HTTP \(status): \(String(decoding: body.prefix(300), as: UTF8.self))\n".utf8))
    }
}
print("Revoked \(revoked) of \(throwaways.count) throwaway certificates.")
