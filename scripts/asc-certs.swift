// App Store Connect certificate chores for CI. Signs the API token with
// CryptoKit, so it runs anywhere `swift` does; no gems, no pip.
//
//   swift scripts/asc-certs.swift <AuthKey.p8> <key id> <issuer id> revoke-ci [--keep-serial HEX]
//   swift scripts/asc-certs.swift <AuthKey.p8> <key id> <issuer id> create <csr.pem> <out.cer>
//
// revoke-ci: `xcodebuild -allowProvisioningUpdates` on a fresh runner mints an
// "Apple Development: Created via API" certificate, and the runner's keychain
// dies with the job. The account fills up and Xcode then fails with "Choose a
// certificate to revoke. Your account has reached the maximum number of
// certificates." (iOS build 37, 2026-09-06). Only certificates whose display
// name is exactly "Created via API" and whose type is a development or App
// Store distribution type are revoked. Developer ID certificates (the Mac
// release), hand-made certificates, and any serial passed with --keep-serial
// (the stored CI certificate) are listed and left alone. DRY_RUN=1 lists only.
//
// create: submits a CSR as an Apple Development certificate and writes the DER
// certificate. The private key never leaves the machine that made the CSR.

import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 5 else {
    FileHandle.standardError.write(Data("usage: asc-certs.swift <AuthKey.p8> <key id> <issuer id> revoke-ci [--keep-serial HEX] | create <csr.pem> <out.cer>\n".utf8))
    exit(2)
}
let keyPath = arguments[1]
let keyID = arguments[2]
let issuerID = arguments[3]
let command = arguments[4]
let options = Array(arguments.dropFirst(5))
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

func request(_ method: String, _ url: URL, token: String, json: [String: Any]? = nil) -> (status: Int, body: Data) {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let json {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: json)
    }
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

struct Certificate {
    let id: String
    let type: String
    let name: String
    let displayName: String
    let serial: String
    let expires: String

    init(_ item: [String: Any]) {
        let attributes = item["attributes"] as? [String: Any] ?? [:]
        id = item["id"] as? String ?? ""
        type = attributes["certificateType"] as? String ?? ""
        name = attributes["name"] as? String ?? ""
        displayName = attributes["displayName"] as? String ?? ""
        serial = (attributes["serialNumber"] as? String ?? "").uppercased()
        expires = attributes["expirationDate"] as? String ?? ""
    }

    func isThrowaway(keeping serials: Set<String>) -> Bool {
        revocableTypes.contains(type) && displayName == throwawayName && !serials.contains(serial)
    }

    var label: String { "\(type) \"\(name): \(displayName)\" serial \(serial) expires \(expires) id \(id)" }
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
        certificates += items.map(Certificate.init)
        let links = json["links"] as? [String: Any]
        next = (links?["next"] as? String).flatMap(URL.init(string:))
    }
    return certificates
}

func revokeCI(token: String) {
    var keep: Set<String> = []
    var index = 0
    while index < options.count {
        if options[index] == "--keep-serial", index + 1 < options.count {
            keep.insert(options[index + 1].uppercased())
            index += 2
        } else {
            fail("Unknown revoke-ci option \(options[index])")
        }
    }
    let certificates = listCertificates(token: token)
    print("Certificates on the account: \(certificates.count)")
    for certificate in certificates {
        let verdict = certificate.isThrowaway(keeping: keep) ? (dryRun ? "would revoke" : "revoke") : "keep"
        print("  \(verdict.padding(toLength: 12, withPad: " ", startingAt: 0)) \(certificate.label)")
    }
    let throwaways = certificates.filter { $0.isThrowaway(keeping: keep) }
    guard !dryRun else { return }
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
}

func create(token: String) {
    guard options.count == 2 else { fail("create needs <csr.pem> <out.cer>") }
    guard let pem = try? String(contentsOfFile: options[0], encoding: .utf8) else { fail("Cannot read \(options[0])") }
    // Apple wants the Base64 body only, without the PEM armor.
    let csrContent = pem.components(separatedBy: .newlines)
        .filter { !$0.hasPrefix("-----") }
        .joined()
    let (status, body) = request(
        "POST", baseURL.appendingPathComponent("v1/certificates"), token: token,
        json: ["data": ["type": "certificates", "attributes": ["certificateType": "DEVELOPMENT", "csrContent": csrContent]]]
    )
    guard status == 201,
          let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
          let item = json["data"] as? [String: Any],
          let content = (item["attributes"] as? [String: Any])?["certificateContent"] as? String,
          let der = Data(base64Encoded: content)
    else {
        fail("POST /v1/certificates returned HTTP \(status): \(String(decoding: body.prefix(500), as: UTF8.self))")
    }
    let certificate = Certificate(item)
    do { try der.write(to: URL(fileURLWithPath: options[1])) } catch { fail("Cannot write \(options[1]): \(error)") }
    print("Created \(certificate.label)")
    print("Wrote \(der.count) bytes to \(options[1])")
}

let token: String
do { token = try makeToken() } catch { fail("Cannot sign the App Store Connect token: \(error)") }
switch command {
case "revoke-ci": revokeCI(token: token)
case "create": create(token: token)
default: fail("Unknown command \(command)")
}
