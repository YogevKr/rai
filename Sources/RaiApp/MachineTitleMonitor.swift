import Foundation
import RaiCore

/// Title-only changes can remain unpublished on an inactive Herdr endpoint.
/// Refresh display metadata after events, without activating or resizing it.
@MainActor
final class MachineTitleMonitor {
    private struct SnapshotResponse: Decodable {
        let snapshot: SessionSnapshot
    }
    let bootID: String
    private let client: HerdrClient
    private let delay: Duration
    private let read: () async throws -> SessionSnapshot
    private let receive: (SessionSnapshot) -> Void
    private var subscription: HerdrEventSubscription?
    private var eventTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var dirty = false
    private var stopped = false

    init(socketPath: String, bootID: String, delay: Duration = .seconds(3),
         read: (() async throws -> SessionSnapshot)? = nil,
         receive: @escaping (SessionSnapshot) -> Void) {
        self.bootID = bootID
        client = HerdrClient(socketPath: socketPath)
        self.delay = delay
        self.receive = receive
        self.read = read ?? {
            let value = try await HerdrPinnedRPC().request(
                socketPath: socketPath,
                endpointSocketPath: RemoteConnection.clientSocketPath(for: socketPath),
                bootID: bootID, method: "session.snapshot", params: [:], timeout: .seconds(10),
                validate: { _ in })
            return try JSONDecoder().decode(SnapshotResponse.self, from: JSONEncoder().encode(value)).snapshot
        }
    }

    deinit {
        subscription?.close()
        eventTask?.cancel()
        refreshTask?.cancel()
    }

    func start() {
        guard !stopped, eventTask == nil else { return }
        let client = client
        eventTask = Task { [weak self] in
            while !Task.isCancelled {
                let subscription = client.subscribe(subscriptions: ["pane.updated", "tab.renamed"])
                self?.subscription = subscription
                do {
                    for try await _ in subscription.messages {
                        guard !Task.isCancelled else { break }
                        self?.requestRefresh()
                    }
                } catch { /* Retry the metadata stream without replacing the terminal connection. */ }
                subscription.close()
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stop() {
        stopped = true
        subscription?.close(); subscription = nil
        eventTask?.cancel(); eventTask = nil
        refreshTask?.cancel(); refreshTask = nil
        dirty = false
    }

    func requestRefresh() {
        guard !stopped else { return }
        dirty = true
        guard refreshTask == nil else { return }
        let delay = delay, read = read
        refreshTask = Task { [weak self] in
            var failures = 0
            repeat {
                do {
                    try await Task.sleep(for: delay)
                    self?.dirty = false
                    let snapshot = try await read()
                    try Task.checkCancellation()
                    guard let self, !self.stopped else { return }
                    failures = 0
                    self.receive(snapshot)
                } catch {
                    guard !Task.isCancelled else { return }
                    // Recover a missed final title after a transient read error.
                    // Bound retries so an unavailable API never becomes idle polling.
                    failures += 1
                    if failures < 3 { self?.dirty = true }
                }
            } while self?.dirty == true
            self?.refreshTask = nil
        }
    }
}
