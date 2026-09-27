import Foundation

/// Persists closed pane records per herd, like the closed tab stack.
struct ClosedPaneStore {
    static let maxRecords = 10
    private static let keyPrefix = "closedPanes.v1."

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func load(herdKey: String) -> [ClosedPaneRecord] {
        guard let data = userDefaults.data(forKey: Self.keyPrefix + herdKey),
              let records = try? JSONDecoder().decode([ClosedPaneRecord].self, from: data)
        else {
            return []
        }
        return Array(records.suffix(Self.maxRecords))
    }

    func save(_ records: [ClosedPaneRecord], herdKey: String) {
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
