import Foundation
import Security

struct APNsConfiguration: Sendable {
    let teamID: String
    let keyID: String
    let bundleID: String
    let keyP8: String
    let defaultEnvironment: String

    var isConfigured: Bool {
        !teamID.isEmpty && !keyID.isEmpty && !bundleID.isEmpty && !keyP8.isEmpty
    }
}

@MainActor
final class APNsSettings: ObservableObject {
    static let shared = APNsSettings()

    @Published var teamID: String {
        didSet { defaults.set(teamID, forKey: Key.teamID) }
    }
    @Published var keyID: String {
        didSet { defaults.set(keyID, forKey: Key.keyID) }
    }
    @Published var bundleID: String {
        didSet { defaults.set(bundleID, forKey: Key.bundleID) }
    }
    @Published var defaultEnvironment: String {
        didSet { defaults.set(defaultEnvironment, forKey: Key.defaultEnvironment) }
    }
    @Published private(set) var keyP8: String

    var isConfigured: Bool { configuration.isConfigured }

    var configuration: APNsConfiguration {
        APNsConfiguration(
            teamID: teamID.trimmingCharacters(in: .whitespacesAndNewlines),
            keyID: keyID.trimmingCharacters(in: .whitespacesAndNewlines),
            bundleID: bundleID.trimmingCharacters(in: .whitespacesAndNewlines),
            keyP8: keyP8.trimmingCharacters(in: .whitespacesAndNewlines),
            defaultEnvironment: defaultEnvironment
        )
    }

    private enum Key {
        static let teamID = "apns.teamID"
        static let keyID = "apns.keyID"
        static let bundleID = "apns.bundleID"
        static let defaultEnvironment = "apns.defaultEnvironment"
        static let keychainService = "gr.krig.rai.apns"
        static let keychainAccount = "auth-key-p8"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        teamID = defaults.string(forKey: Key.teamID) ?? ""
        keyID = defaults.string(forKey: Key.keyID) ?? ""
        bundleID = defaults.string(forKey: Key.bundleID) ?? "gr.krig.rai.ios"
        defaultEnvironment = defaults.string(forKey: Key.defaultEnvironment) ?? "sandbox"
        keyP8 = Self.readKey()
    }

    func setKeyP8(_ value: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Key.keychainService,
            kSecAttrAccount as String: Key.keychainAccount,
        ]
        let status: OSStatus
        if value.isEmpty {
            status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError(status: status)
            }
        } else {
            let attributes = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if updateStatus == errSecItemNotFound {
                var newItem = query
                newItem[kSecValueData as String] = data
                status = SecItemAdd(newItem as CFDictionary, nil)
            } else {
                status = updateStatus
            }
            guard status == errSecSuccess else {
                throw KeychainError(status: status)
            }
        }
        keyP8 = value
    }

    private static func readKey() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Key.keychainService,
            kSecAttrAccount as String: Key.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String?
            ?? "Keychain error \(status)"
    }
}
