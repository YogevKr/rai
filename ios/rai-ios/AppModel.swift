import CryptoKit
import Foundation
import RaiCore

private enum SnapshotCacheError: Error {
    case invalidSnapshot
}

struct CachedHerdSnapshot: Codable, Equatable {
    let snapshot: SessionSnapshot
    let savedAt: Date
    let pairingID: String

    func belongs(to pairing: Pairing) -> Bool {
        pairingID == Self.pairingID(for: pairing)
    }

    static func pairingID(for pairing: Pairing) -> String {
        let value = "\(pairing.host.lowercased())|\(pairing.port)|\(pairing.useTLS)|\(pairing.token)"
        return SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// Stores only the herd model. Terminal frames stay memory-only.
final class SnapshotCacheStore {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "rai.snapshot-cache")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileURL: URL = SnapshotCacheStore.defaultURL()) {
        self.fileURL = fileURL
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() -> CachedHerdSnapshot? {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            return try? decoder.decode(CachedHerdSnapshot.self, from: data)
        }
    }

    func save(_ cached: CachedHerdSnapshot) throws {
        try queue.sync {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let sanitized = CachedHerdSnapshot(
                snapshot: try sanitizedSnapshot(cached.snapshot),
                savedAt: cached.savedAt,
                pairingID: cached.pairingID
            )
            try encoder.encode(sanitized).write(to: fileURL, options: .atomic)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var savedURL = fileURL
            do {
                try savedURL.setResourceValues(values)
            } catch {
                try? FileManager.default.removeItem(at: fileURL)
                throw error
            }
        }
    }

    func clear() {
        queue.sync {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                NSLog("rai-ios: Could not clear snapshot cache: %@", error.localizedDescription)
            }
        }
    }

    private static func defaultURL() -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("com.whetstone.rai.ios", isDirectory: true)
            .appendingPathComponent("last-herd-snapshot.json")
    }

    private func sanitizedSnapshot(_ snapshot: SessionSnapshot) throws -> SessionSnapshot {
        let data = try encoder.encode(snapshot)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var panes = root["panes"] as? [[String: Any]] else {
            throw SnapshotCacheError.invalidSnapshot
        }
        for index in panes.indices {
            panes[index].removeValue(forKey: "agent_session")
            panes[index].removeValue(forKey: "foreground_cwd")
            panes[index].removeValue(forKey: "scroll")
            panes[index].removeValue(forKey: "terminal_title")
            if let cwd = panes[index]["cwd"] as? String {
                panes[index]["cwd"] = (cwd as NSString).lastPathComponent
            }
        }
        root["panes"] = panes
        if var workspaces = root["workspaces"] as? [[String: Any]] {
            for index in workspaces.indices {
                workspaces[index].removeValue(forKey: "worktree")
            }
            root["workspaces"] = workspaces
        }
        root.removeValue(forKey: "agents")
        root["layouts"] = []
        let sanitizedData = try JSONSerialization.data(withJSONObject: root)
        return try decoder.decode(SessionSnapshot.self, from: sanitizedData)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var pairing: Pairing?
    @Published var pendingOpenPaneID: String?
    @Published private(set) var backgroundWorkByPaneID: [String: [String]] = [:]
    let connection: BridgeConnection

    private let pairingStore: PairingStore
    private let snapshotCacheStore: SnapshotCacheStore
    private var deviceToken: String?
    private var pendingCache: CachedHerdSnapshot?
    private var cacheWriteTask: Task<Void, Never>?

    init(
        connection: BridgeConnection? = nil,
        pairingStore: PairingStore = PairingStore(),
        snapshotCacheStore: SnapshotCacheStore = SnapshotCacheStore()
    ) {
        let connection = connection ?? BridgeConnection()
        self.connection = connection
        self.pairingStore = pairingStore
        self.snapshotCacheStore = snapshotCacheStore
        connection.didConnect = { [weak self] in
            self?.registerPushIfPossible()
        }
        connection.didReceiveSnapshot = { [weak self] snapshot, receivedAt in
            self?.scheduleSnapshotCache(snapshot, receivedAt: receivedAt)
        }
        connection.didReceiveBackgroundWork = { [weak self] work in
            self?.backgroundWorkByPaneID = Dictionary(
                work.map { ($0.paneID, $0.summaries) },
                uniquingKeysWith: { _, latest in latest }
            )
        }
        // Testing/automation affordance: pair straight from a launch env var,
        // e.g. `simctl launch --setenv RAI_PAIR_URL "rai://pair?..."`. Harmless
        // in normal use (the var is never set); lets e2e tests skip the QR/UI.
        if let urlString = ProcessInfo.processInfo.environment["RAI_PAIR_URL"] {
            NSLog("rai-ios: RAI_PAIR_URL present: \(urlString)")
            if let launchPairing = try? Pairing(urlString: urlString) {
                activate(launchPairing, persist: true)
                return
            } else {
                NSLog("rai-ios: RAI_PAIR_URL failed to parse")
            }
        }
        if let storedPairing = pairingStore.load() {
            activate(storedPairing, persist: false)
        }
    }

    func pair(_ pairing: Pairing) {
        activate(pairing, persist: true)
    }

    private func activate(_ pairing: Pairing, persist: Bool) {
        let changesMac = self.pairing.map { $0 != pairing } ?? false
        if changesMac {
            discardSnapshotCache()
        }
        self.pairing = pairing
        if connection.snapshot == nil, let cached = snapshotCacheStore.load() {
            if cached.belongs(to: pairing) {
                connection.restoreCachedSnapshot(cached)
            } else {
                snapshotCacheStore.clear()
            }
        }
        connection.connect(to: pairing)
        guard persist else { return }
        do {
            try pairingStore.save(pairing)
        } catch {
            // Connecting must not depend on Keychain availability. In particular,
            // unsigned simulator builds may lack the required entitlement.
            NSLog("rai-ios: Could not persist pairing: \(error.localizedDescription)")
        }
    }

    func forgetPairing() {
        // Revoke push delivery on the Mac before dropping the socket, otherwise
        // it keeps this device registered and notifying after the user has
        // explicitly forgotten the pairing.
        let token = deviceToken
        Task {
            if let token, connection.status.isConnected {
                await connection.unregisterPush(deviceToken: token)
            }
            connection.disconnect()
        }
        pairingStore.clear()
        discardSnapshotCache()
        pairing = nil
    }

    func setPushDeviceToken(_ token: String) {
        deviceToken = token
        registerPushIfPossible()
    }

    func sendNotificationInput(_ bytes: [UInt8], to paneID: String) async -> Bool {
        guard let pairing else { return false }
        return await connection.connectAndSendInput(bytes, to: paneID, pairing: pairing)
    }

    private func registerPushIfPossible() {
        guard let deviceToken, connection.status.isConnected else { return }
        connection.registerPush(
            deviceToken: deviceToken,
            environment: Self.apnsEnvironment
        )
    }

    private func scheduleSnapshotCache(_ snapshot: SessionSnapshot, receivedAt: Date) {
        guard let pairing else { return }
        let cached = CachedHerdSnapshot(
            snapshot: snapshot,
            savedAt: receivedAt,
            pairingID: CachedHerdSnapshot.pairingID(for: pairing)
        )
        guard cacheWriteTask == nil else {
            pendingCache = cached
            return
        }

        persistSnapshotCache(cached)
        startCacheWriteCooldown()
    }

    private func startCacheWriteCooldown() {
        cacheWriteTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                self?.cacheWriteTask = nil
                return
            }
            guard let self, let cached = self.pendingCache else {
                self?.cacheWriteTask = nil
                return
            }
            self.pendingCache = nil
            self.cacheWriteTask = nil
            self.persistSnapshotCache(cached)
            self.startCacheWriteCooldown()
        }
    }

    private func persistSnapshotCache(_ cached: CachedHerdSnapshot) {
        do {
            try snapshotCacheStore.save(cached)
        } catch {
            NSLog("rai-ios: Could not persist snapshot cache: %@", error.localizedDescription)
        }
    }

    private func discardSnapshotCache() {
        cacheWriteTask?.cancel()
        cacheWriteTask = nil
        pendingCache = nil
        snapshotCacheStore.clear()
    }

    /// The APNs token's environment is fixed by the signed `aps-environment`
    /// entitlement, not the build configuration — a Release build run from Xcode
    /// on a development profile still gets a *sandbox* token. Read it from the
    /// embedded provisioning profile; fall back to the build config when there
    /// is no profile (e.g. the simulator).
    static let apnsEnvironment: String = {
        if let url = Bundle.main.url(
            forResource: "embedded",
            withExtension: "mobileprovision"
        ),
           let data = try? Data(contentsOf: url),
           let raw = String(data: data, encoding: .ascii),
           let start = raw.range(of: "<plist"),
           let end = raw.range(of: "</plist>"),
           let plistData = String(raw[start.lowerBound..<end.upperBound])
               .data(using: .utf8),
           let plist = try? PropertyListSerialization.propertyList(
               from: plistData, format: nil
           ) as? [String: Any],
           let entitlements = plist["Entitlements"] as? [String: Any],
           let aps = entitlements["aps-environment"] as? String {
            // Entitlement values are "development" or "production".
            return aps == "production" ? "production" : "sandbox"
        }
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }()
}
