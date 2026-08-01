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
    /// The auth key, read from the keychain ON DEMAND.
    ///
    /// Reading it at launch made every start of rai hit the keychain — and any
    /// re-signed build (a new version, a fresh `bundle.sh` install) no longer
    /// matches the item's ACL, so macOS put a password dialog in front of the
    /// app before it had drawn a window, on the main thread. The key is only
    /// ever needed to SEND a push or to edit it in Settings, so it is fetched
    /// then, and cached for the rest of the process.
    var keyP8: String {
        if let cachedKeyP8 { return cachedKeyP8 }
        let value = Self.readKey()
        cachedKeyP8 = value
        return value
    }

    private var cachedKeyP8: String?

    /// True when a key has been stored, WITHOUT reading it back: the flag is a
    /// plain default, so asking "is push set up?" never opens the keychain.
    var hasStoredKey: Bool { defaults.bool(forKey: Key.hasKey) }

    /// Whether push can be sent. Deliberately avoids the key itself so callers
    /// on the launch path stay keychain-free.
    var isConfigured: Bool {
        !teamID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !keyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasStoredKey
    }

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
        static let hasKey = "apns.hasKey"
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
        // No keychain read here. See `keyP8`.
        //
        // Older builds tracked the key's presence only by holding the key, so
        // adopt the flag once for a user who already stored one.
        if defaults.object(forKey: Key.hasKey) == nil {
            defaults.set(Self.keyExists(), forKey: Key.hasKey)
        }
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
        cachedKeyP8 = value
        defaults.set(!value.isEmpty, forKey: Key.hasKey)
    }

    /// Does an item exist, without decrypting it? Asking for attributes rather
    /// than data leaves the ACL untouched, so this cannot raise a dialog — the
    /// whole point of the flag it backfills.
    private static func keyExists() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Key.keychainService,
            kSecAttrAccount as String: Key.keychainAccount,
            kSecReturnData as String: false,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
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
