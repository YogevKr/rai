/// Tracks keys from least to most recently used and reports overflow evictions.
///
/// This intentionally stores only recency. The owner keeps the corresponding
/// values and decides how to dispose of an evicted key.
public struct LRUTracker<Key: Hashable> {
    public private(set) var capacity: Int
    private var keys: [Key] = []

    public init(capacity: Int) {
        precondition(capacity > 0, "LRU capacity must be positive")
        self.capacity = capacity
    }

    /// Re-bounds the tracker, returning the keys evicted to fit a smaller
    /// capacity (least-recent first). Growing evicts nothing.
    @discardableResult
    public mutating func setCapacity(_ newCapacity: Int) -> [Key] {
        precondition(newCapacity > 0, "LRU capacity must be positive")
        capacity = newCapacity
        guard keys.count > capacity else { return [] }
        let overflow = keys.count - capacity
        let evicted = Array(keys.prefix(overflow))
        keys.removeFirst(overflow)
        return evicted
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

    public var mostToLeastRecent: [Key] {
        keys.reversed()
    }

    public var leastToMostRecent: [Key] {
        keys
    }
}
