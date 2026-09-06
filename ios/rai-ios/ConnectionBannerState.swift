import Combine
import Foundation

/// Keep transient failures out of the layout while automatic recovery runs.
@MainActor
final class ConnectionBannerState: ObservableObject {
    @Published private(set) var diagnosis: ConnectionDiagnosis?
    private var latestDiagnosis: ConnectionDiagnosis?
    private var delayTask: Task<Void, Never>?
    private let sleep: (Duration) async throws -> Void

    init(sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    deinit { delayTask?.cancel() }

    func update(_ status: BridgeConnection.Status) {
        switch status {
        case .connected, .disconnected:
            delayTask?.cancel()
            delayTask = nil
            latestDiagnosis = nil
            diagnosis = nil
        case .connecting:
            // Retry attempts belong to the same outage. Keep its deadline and
            // any visible diagnosis until authentication succeeds.
            break
        case let .failed(failure):
            latestDiagnosis = failure
            if failure.action == .pairAgain || diagnosis != nil {
                delayTask?.cancel()
                delayTask = nil
                diagnosis = failure
            } else if delayTask == nil {
                let sleep = sleep
                delayTask = Task { @MainActor [weak self] in
                    do { try await sleep(.seconds(3)) } catch { return }
                    guard !Task.isCancelled, let self else { return }
                    self.diagnosis = self.latestDiagnosis
                    self.delayTask = nil
                }
            }
        }
    }
}
