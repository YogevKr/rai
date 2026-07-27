import Foundation
import Security

struct Pairing: Equatable {
    let host: String
    let port: Int
    let token: String

    init(host: String, port: Int, token: String) throws {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { throw PairingError.invalidHost }
        guard (1...65_535).contains(port) else { throw PairingError.invalidPort }
        guard !trimmedToken.isEmpty else { throw PairingError.invalidToken }

        self.host = trimmedHost
        self.port = port
        self.token = trimmedToken
    }

    init(urlString: String) throws {
        guard let components = URLComponents(string: urlString),
              components.scheme?.lowercased() == "rai",
              components.host?.lowercased() == "pair" else {
            throw PairingError.invalidCode
        }
        let queryItems = components.queryItems ?? []
        guard let host = queryItems.first(where: { $0.name == "host" })?.value,
              let portString = queryItems.first(where: { $0.name == "port" })?.value,
              let port = Int(portString),
              let token = queryItems.first(where: { $0.name == "token" })?.value else {
            throw PairingError.invalidCode
        }
        try self.init(host: host, port: port, token: token)
    }
}

enum PairingError: LocalizedError {
    case invalidCode
    case invalidHost
    case invalidPort
    case invalidToken
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidCode: "That is not a valid rai pairing code."
        case .invalidHost: "Enter the Mac's host name or IP address."
        case .invalidPort: "Port must be between 1 and 65535."
        case .invalidToken: "Enter the pairing token."
        case let .keychain(status): "Could not save the token (Keychain error \(status))."
        }
    }
}

final class PairingStore {
    private let defaults: UserDefaults
    private let service = "gr.krig.rai.ios.bridge"
    private let account = "pairing-token"
    private let hostKey = "bridge.host"
    private let portKey = "bridge.port"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> Pairing? {
        guard let host = defaults.string(forKey: hostKey),
              let token = readToken() else { return nil }
        let port = defaults.integer(forKey: portKey)
        return try? Pairing(host: host, port: port, token: token)
    }

    func save(_ pairing: Pairing) throws {
        let tokenData = Data(pairing.token.utf8)
        let query = baseQuery()
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData: tokenData] as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = tokenData
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw PairingError.keychain(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw PairingError.keychain(updateStatus)
        }

        defaults.set(pairing.host, forKey: hostKey)
        defaults.set(pairing.port, forKey: portKey)
    }

    func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
        defaults.removeObject(forKey: hostKey)
        defaults.removeObject(forKey: portKey)
    }

    private func readToken() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
