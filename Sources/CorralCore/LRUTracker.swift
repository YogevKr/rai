/// Tracks keys from least to most recently used and reports overflow evictions.
///
/// This intentionally stores only recency. The owner keeps the corresponding
/// values and decides how to dispose of an evicted key.
public struct LRUTracker<Key: Hashable> {
    public let capacity: Int
    private var keys: [Key] = []

    public init(capacity: Int) {
        precondition(capacity > 0, "LRU capacity must be positive")
        self.capacity = capacity
    }

    /// Marks `key` as most recently used, returning the least-recent key when
    /// the capacity is exceeded.
    @discardableResult
    public mutating func touch(_ key: Key) -> Key? {
        if let existingIndex = keys.firstIndex(of: key) {
            keys.remove(at: existingIndex)
        }
        keys.append(key)
        return keys.count > capacity ? keys.removeFirst() : nil
    }

    public mutating func remove(_ key: Key) {
        keys.removeAll { $0 == key }
    }

    public var leastToMostRecent: [Key] {
        keys
    }
}
