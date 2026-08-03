import Foundation

/// Persists the reopen stack across app launches, keyed by herd.
///
/// Per-herd keying is load-bearing, not just tidiness: a record names a
/// workspace and cwds on ONE herd's host. Reopening it while attached to a
/// different herd would rebuild the tab against the wrong machine, so each
/// herd gets its own stack and connecting swaps the whole stack in.
///
/// Records deliberately carry no terminal text — herdr's own docs treat pane
/// contents as secret-bearing, and this store writes to disk.
struct ClosedTabStore {
    static let maxRecords = 10
    private static let keyPrefix = "closedTabs.v1."

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// One stack per herd: the local session name, or target#session for a
    /// remote herd, so two herds named "default" on different hosts stay apart.
    static func herdKey(sessionName: String, remoteTarget: String?) -> String {
        guard let remoteTarget else { return sessionName }
        return "\(remoteTarget)#\(sessionName)"
    }

    func load(herdKey: String) -> [ClosedTabRecord] {
        guard let data = userDefaults.data(forKey: Self.keyPrefix + herdKey),
              let records = try? JSONDecoder().decode([ClosedTabRecord].self, from: data)
        else {
            return []
        }
        return Array(records.suffix(Self.maxRecords))
    }

    func save(_ records: [ClosedTabRecord], herdKey: String) {
        let key = Self.keyPrefix + herdKey
        guard !records.isEmpty else {
            userDefaults.removeObject(forKey: key)
            return
        }
        let capped = Array(records.suffix(Self.maxRecords))
        guard let data = try? JSONEncoder().encode(capped) else { return }
        userDefaults.set(data, forKey: key)
    }
}
