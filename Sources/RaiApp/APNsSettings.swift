import CryptoKit
import Darwin
import Foundation
import Security

enum APNsKeyReadState: Equatable, Sendable {
    case missing
    case readable
    case unreadable
}

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

enum APNsKeyFileError: LocalizedError {
    case invalid(APNsKeyError)
    case createDirectory(String)
    case write(String)

    var errorDescription: String? {
        switch self {
        case let .invalid(error):
            return error.localizedDescription
        case let .createDirectory(detail):
            return "Could not prepare the APNs key directory: \(detail)"
        case let .write(detail):
            return "Could not save the APNs key file: \(detail)"
        }
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

    let keyFileURL: URL

    var keyP8: String {
        guard let data = try? Data(contentsOf: keyFileURL),
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    var keyProblem: String? {
        if migrationProblem == .invalid {
            return "The old Keychain item is not a valid APNs .p8 key. Paste the key again."
        }
        if migrationProblem == .unreadable {
            return "The old APNs Keychain item could not be read. Paste the key again."
        }
        guard FileManager.default.fileExists(atPath: keyFileURL.path) else {
            return "No APNs key file exists. Paste the .p8 in Settings → iPhone."
        }
        guard let data = try? Data(contentsOf: keyFileURL),
              let value = String(data: data, encoding: .utf8) else {
            return "The APNs key file could not be read. Paste the key again."
        }
        do {
            _ = try APNsKeyParser.privateKey(from: value)
            return nil
        } catch {
            return "The APNs key file is invalid: \(error.localizedDescription)"
        }
    }

    var hasStoredKey: Bool {
        FileManager.default.fileExists(atPath: keyFileURL.path)
    }

    var isConfigured: Bool {
        !teamID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !keyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && keyReadState == .readable
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

    var keyReadState: APNsKeyReadState {
        if migrationProblem != nil { return .unreadable }
        guard FileManager.default.fileExists(atPath: keyFileURL.path) else { return .missing }
        guard let data = try? Data(contentsOf: keyFileURL),
              let value = String(data: data, encoding: .utf8),
              (try? APNsKeyParser.privateKey(from: value)) != nil else {
            return .unreadable
        }
        return .readable
    }

    /// Reads the legacy key: `(pem, status)`. Injectable for migration tests.
    typealias KeyReader = () -> (String, OSStatus)

    private enum MigrationProblem: String {
        case invalid
        case unreadable
    }

    private enum Key {
        static let teamID = "apns.teamID"
        static let keyID = "apns.keyID"
        static let bundleID = "apns.bundleID"
        static let defaultEnvironment = "apns.defaultEnvironment"
        static let migrationAttempted = "apns.keyFileMigrationAttempted"
        static let migrationProblem = "apns.keyFileMigrationProblem"
        static let keychainService = "gr.krig.rai.apns"
        static let keychainAccount = "auth-key-p8"
    }

    private let defaults: UserDefaults
    private let keyReader: KeyReader
    private var migrationProblem: MigrationProblem?

    init(
        defaults: UserDefaults = .standard,
        keyFileURL: URL = APNsSettings.defaultKeyFileURL,
        migrateImmediately: Bool = false,
        keyReader: @escaping KeyReader = APNsSettings.readLegacyKey
    ) {
        self.defaults = defaults
        self.keyFileURL = keyFileURL
        self.keyReader = keyReader
        migrationProblem = defaults.string(forKey: Key.migrationProblem)
            .flatMap(MigrationProblem.init(rawValue:))
        teamID = defaults.string(forKey: Key.teamID) ?? ""
        keyID = defaults.string(forKey: Key.keyID) ?? ""
        bundleID = defaults.string(forKey: Key.bundleID) ?? "com.whetstone.rai.ios"
        defaultEnvironment = defaults.string(forKey: Key.defaultEnvironment) ?? "sandbox"
        if migrateImmediately {
            migrateLegacyKeyIfNeeded()
        }
    }

    func setKeyP8(_ value: String) throws {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if FileManager.default.fileExists(atPath: keyFileURL.path) {
                try FileManager.default.removeItem(at: keyFileURL)
            }
            migrationProblem = nil
            defaults.removeObject(forKey: Key.migrationProblem)
            defaults.set(true, forKey: Key.migrationAttempted)
            return
        }
        let key: P256.Signing.PrivateKey
        do {
            key = try APNsKeyParser.privateKey(from: value)
        } catch let error as APNsKeyError {
            throw APNsKeyFileError.invalid(error)
        }
        try writeKeyFile(key.pemRepresentation)
        migrationProblem = nil
        defaults.removeObject(forKey: Key.migrationProblem)
        defaults.set(true, forKey: Key.migrationAttempted)
    }

    func migrateLegacyKeyIfNeeded() {
        if FileManager.default.fileExists(atPath: keyFileURL.path) {
            migrationProblem = nil
            defaults.removeObject(forKey: Key.migrationProblem)
            defaults.set(true, forKey: Key.migrationAttempted)
            return
        }
        let attempted = defaults.bool(forKey: Key.migrationAttempted)
        guard !attempted || migrationProblem == .unreadable else { return }

        let (value, status) = keyReader()
        guard status != errSecItemNotFound else {
            migrationProblem = nil
            defaults.removeObject(forKey: Key.migrationProblem)
            defaults.set(true, forKey: Key.migrationAttempted)
            return
        }
        guard status == errSecSuccess else {
            recordMigrationProblem(.unreadable)
            return
        }
        let key: P256.Signing.PrivateKey
        do {
            key = try APNsKeyParser.privateKey(from: value)
        } catch {
            recordMigrationProblem(.invalid)
            defaults.set(true, forKey: Key.migrationAttempted)
            return
        }
        do {
            try writeKeyFile(key.pemRepresentation)
            migrationProblem = nil
            defaults.removeObject(forKey: Key.migrationProblem)
            defaults.set(true, forKey: Key.migrationAttempted)
        } catch {
            recordMigrationProblem(.unreadable)
        }
    }

    private func recordMigrationProblem(_ problem: MigrationProblem) {
        migrationProblem = problem
        defaults.set(problem.rawValue, forKey: Key.migrationProblem)
    }

    private func writeKeyFile(_ value: String) throws {
        let manager = FileManager.default
        let directory = keyFileURL.deletingLastPathComponent()
        do {
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            throw APNsKeyFileError.createDirectory(error.localizedDescription)
        }

        let temporaryURL = directory.appendingPathComponent(".apns-key-\(UUID().uuidString).tmp")
        do {
            try Data(value.utf8).write(to: temporaryURL, options: .withoutOverwriting)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
            guard rename(temporaryURL.path, keyFileURL.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? manager.removeItem(at: temporaryURL)
            throw APNsKeyFileError.write(error.localizedDescription)
        }
    }

    nonisolated private static var defaultKeyFileURL: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("Rai", isDirectory: true)
            .appendingPathComponent("apns-key.p8")
    }

    nonisolated private static func readLegacyKey() -> (String, OSStatus) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Key.keychainService,
            kSecAttrAccount as String: Key.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return ("", status) }
        return (String(data: data, encoding: .utf8) ?? "", status)
    }
}
