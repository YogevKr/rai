import Foundation

public enum HerdrEventMessage: Sendable {
    case ready
    case event(HerdrEvent)
}

/// Owns a subscription, including a blocked socket read and buffered events.
public final class HerdrEventSubscription: Sendable {
    public let messages: AsyncThrowingStream<HerdrEventMessage, Error>
    private let cancel: @Sendable () -> Void

    init(
        messages: AsyncThrowingStream<HerdrEventMessage, Error>,
        cancel: @escaping @Sendable () -> Void
    ) {
        self.messages = messages
        self.cancel = cancel
    }

    public func close() { cancel() }
    deinit { cancel() }
}

public struct HerdrEventFilter: Equatable, Sendable {
    public let subscriptions: [String]
    public let paneIDs: [String]

    public init(snapshot: SessionSnapshot?) {
        subscriptions = HerdrClient.subscriptions(forProtocol: snapshot?.protocol)
        paneIDs = (snapshot?.panes.map(\.paneID) ?? []).sorted()
    }
}
