import Foundation

/// Combines adjacent committed text while its ordered transport write is pending.
/// A key, paste, target change, or started write closes the batch at the caller.
@MainActor
public final class EndpointTextBatch<Context: Equatable> {
    public let context: Context
    public private(set) var text: String
    private var pending = true
    public var byteCount: Int { text.utf8.count + 16 }

    public init(context: Context, text: String) {
        self.context = context
        self.text = text
    }

    public func append(_ text: String, context: Context) -> Bool {
        guard pending, self.context == context,
              text.utf8.count <= 32_768 - self.text.utf8.count else { return false }
        self.text.append(contentsOf: text)
        return true
    }

    public func seal() -> String {
        pending = false
        return text
    }
}
