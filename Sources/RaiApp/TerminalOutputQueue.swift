import Foundation

/// Retains input order and acknowledges each transport read after parsing.
@MainActor
final class TerminalOutputQueue {
    private struct Entry {
        let bytes: [UInt8]
        let complete: () -> Void
    }
    private var entries: [Entry?] = []
    private var head = 0
    private var offset = 0
    private(set) var byteCount = 0
    var isEmpty: Bool { byteCount == 0 }

    func append(_ bytes: ArraySlice<UInt8>, completion: @escaping () -> Void) {
        guard !bytes.isEmpty else { completion(); return }
        entries.append(Entry(bytes: Array(bytes), complete: completion))
        byteCount += bytes.count
    }

    func next(maxBytes: Int) -> (bytes: ArraySlice<UInt8>, complete: () -> Void)? {
        guard !isEmpty, maxBytes > 0, let entry = entries[head] else { return nil }
        let end = min(entry.bytes.count, offset + maxBytes)
        let bytes = entry.bytes[offset..<end]
        byteCount -= bytes.count
        offset = end
        var complete: () -> Void = {}
        if offset == entry.bytes.count {
            complete = entry.complete
            entries[head] = nil
            head += 1
            offset = 0
            if head == entries.count {
                entries.removeAll(keepingCapacity: true)
                head = 0
            }
        }
        return (bytes, complete)
    }

    func discard() {
        let remaining = entries.compactMap { $0?.complete }
        entries.removeAll(keepingCapacity: true)
        head = 0
        offset = 0
        byteCount = 0
        for complete in remaining { complete() }
    }
}
