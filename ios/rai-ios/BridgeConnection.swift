import Foundation
import RaiCore
import UIKit

@MainActor
final class BridgeConnection: ObservableObject {
    enum Status: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(reason: String)

        var label: String {
            switch self {
            case .disconnected: "Disconnected"
            case .connecting: "Connecting…"
            case .connected: "Connected"
            case let .failed(reason): reason
            }
        }

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    @Published private(set) var status: Status = .disconnected
    @Published private(set) var snapshot: SessionSnapshot?
    @Published private(set) var requiresRepair = false
    var didConnect: (() -> Void)?

    var host: String {
        pairing?.host ?? "Mac"
    }

    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var pairing: Pairing?
    private var reconnectAttempt = 0
    private var shouldReconnect = false
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var paneFrameHandlers: [String: [UUID: (Data, Bool) -> Void]] = [:]
    private var desiredStreams: [String: (cols: Int, rows: Int)] = [:]

    func connect(to pairing: Pairing) {
        disconnect(clearPairing: false)
        self.pairing = pairing
        shouldReconnect = true
        requiresRepair = false
        reconnectAttempt = 0
        openSocket()
    }

    func disconnect() {
        disconnect(clearPairing: true)
    }

    func retryNow() {
        guard pairing != nil else { return }
        task?.cancel(with: .goingAway, reason: nil)
        receiveTask?.cancel()
        reconnectTask?.cancel()
        reconnectAttempt = 0
        shouldReconnect = true
        requiresRepair = false
        openSocket()
    }

    func refreshSnapshot() async {
        guard status.isConnected else {
            retryNow()
            return
        }
        do {
            try await send(.subscribe)
        } catch {
            handleSocketFailure(error)
        }
    }

    func openPane(paneID: String, cols: Int = 80, rows: Int = 24) {
        let size = desiredStreams[paneID] ?? (cols, rows)
        desiredStreams[paneID] = size
        Task {
            do {
                try await send(.selectPane(paneID: paneID))
                try await send(.focusPane(paneID: paneID))
                try await send(
                    .attachStream(paneID: paneID, cols: size.cols, rows: size.rows)
                )
            } catch {
                handleSocketFailure(error)
            }
        }
    }

    func closePane(paneID: String) {
        desiredStreams.removeValue(forKey: paneID)
        Task {
            do {
                try await send(.detachStream(paneID: paneID))
            } catch {
                handleSocketFailure(error)
            }
        }
    }

    func resizePane(paneID: String, cols: Int, rows: Int) {
        guard cols > 0, rows > 0,
              desiredStreams[paneID]?.cols != cols || desiredStreams[paneID]?.rows != rows
        else { return }
        desiredStreams[paneID] = (cols, rows)
        Task {
            do {
                try await send(.resizePane(paneID: paneID, cols: cols, rows: rows))
            } catch {
                handleSocketFailure(error)
            }
        }
    }

    func addPaneFrameHandler(
        for paneID: String,
        handler: @escaping (Data, Bool) -> Void
    ) -> UUID {
        let id = UUID()
        paneFrameHandlers[paneID, default: [:]][id] = handler
        return id
    }

    func removePaneFrameHandler(for paneID: String, id: UUID) {
        paneFrameHandlers[paneID]?.removeValue(forKey: id)
        if paneFrameHandlers[paneID]?.isEmpty == true {
            paneFrameHandlers.removeValue(forKey: paneID)
        }
    }

    func sendInput(_ bytes: [UInt8], to paneID: String) {
        Task {
            do {
                try await send(
                    .input(
                        paneID: paneID,
                        bytesBase64: Data(bytes).base64EncodedString()
                    )
                )
            } catch {
                handleSocketFailure(error)
            }
        }
    }

    func registerPush(deviceToken: String, environment: String) {
        Task {
            do {
                try await send(
                    .registerPush(deviceToken: deviceToken, environment: environment)
                )
            } catch {
                handleSocketFailure(error)
            }
        }
    }

    /// Best-effort unregister on the still-open socket. Awaited so callers can
    /// flush it before tearing the connection down (e.g. forgetting a pairing).
    func unregisterPush(deviceToken: String) async {
        try? await send(.unregisterPush(deviceToken: deviceToken))
    }

    private func openSocket() {
        guard let pairing, let url = webSocketURL(for: pairing), shouldReconnect else {
            status = .failed(reason: "Invalid bridge address")
            return
        }

        reconnectTask?.cancel()
        status = .connecting
        let socket = URLSession.shared.webSocketTask(with: url)
        task = socket
        socket.resume()

        receiveTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.sendHelloAndSubscribe(pairing: pairing)
                try await self.receiveMessages(from: socket)
            } catch is CancellationError {
                return
            } catch {
                self.handleSocketFailure(error, from: socket)
            }
        }
    }

    private func sendHelloAndSubscribe(pairing: Pairing) async throws {
        let defaults = UserDefaults.standard
        let deviceIDKey = "bridge.deviceID"
        let deviceID: String
        if let existing = defaults.string(forKey: deviceIDKey) {
            deviceID = existing
        } else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: deviceIDKey)
        }
        let client = ClientInfo(
            deviceID: deviceID,
            name: UIDevice.current.name,
            platform: "iOS"
        )
        try await send(.hello(token: pairing.token, client: client))
        try await send(.subscribe)
    }

    private func receiveMessages(from socket: URLSessionWebSocketTask) async throws {
        while !Task.isCancelled {
            let frame = try await socket.receive()
            let data: Data
            switch frame {
            case let .string(text):
                data = Data(text.utf8)
            case .data:
                continue
            @unknown default:
                continue
            }
            handle(try decoder.decode(BridgeMessage.self, from: data))
        }
    }

    private func handle(_ message: BridgeMessage) {
        switch message {
        case let .welcome(protocolVersion, _):
            guard protocolVersion == bridgeProtocolVersion else {
                stopWithFailure("Unsupported bridge protocol \(protocolVersion)")
                return
            }
            reconnectAttempt = 0
            status = .connected
            didConnect?()
            for (paneID, size) in desiredStreams {
                Task {
                    do {
                        try await send(
                            .attachStream(paneID: paneID, cols: size.cols, rows: size.rows)
                        )
                    } catch {
                        handleSocketFailure(error)
                    }
                }
            }
        case let .authFailed(reason):
            requiresRepair = true
            stopWithFailure("Re-pair required: \(reason)")
        case let .snapshot(snapshot):
            self.snapshot = snapshot
        case let .paneFrame(paneID, bytesBase64, full, _):
            guard let data = Data(base64Encoded: bytesBase64) else { return }
            guard let handlers = paneFrameHandlers[paneID]?.values else { return }
            for handler in handlers {
                handler(data, full)
            }
        case let .error(message):
            status = .failed(reason: message)
        case .event:
            break
        case .hello, .subscribe, .attachStream, .detachStream,
             .input, .focusPane, .selectPane, .resizePane,
             .registerPush, .unregisterPush:
            break
        }
    }

    private func send(_ message: BridgeMessage) async throws {
        guard let task else { throw URLError(.notConnectedToInternet) }
        let data = try encoder.encode(message)
        guard let text = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        try await task.send(.string(text))
    }

    private func handleSocketFailure(
        _ error: Error,
        from socket: URLSessionWebSocketTask? = nil
    ) {
        guard shouldReconnect, !(error is CancellationError) else { return }
        if let socket, task !== socket {
            return
        }
        scheduleReconnect(after: error)
    }

    private func scheduleReconnect(after error: Error) {
        guard reconnectTask == nil || reconnectTask?.isCancelled == true else { return }
        task = nil
        receiveTask = nil
        reconnectAttempt += 1
        status = .failed(reason: failureReason(for: error))
        let delay = min(pow(2.0, Double(reconnectAttempt - 1)), 30)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.shouldReconnect else { return }
            self.reconnectTask = nil
            self.openSocket()
        }
    }

    private func stopWithFailure(_ message: String) {
        shouldReconnect = false
        task?.cancel(with: .policyViolation, reason: nil)
        task = nil
        receiveTask?.cancel()
        receiveTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        status = .failed(reason: message)
    }

    private func disconnect(clearPairing: Bool) {
        shouldReconnect = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        receiveTask?.cancel()
        receiveTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        status = .disconnected
        requiresRepair = false
        snapshot = nil
        desiredStreams.removeAll()
        if clearPairing { pairing = nil }
    }

    private func webSocketURL(for pairing: Pairing) -> URL? {
        var components = URLComponents()
        components.scheme = "ws"
        components.host = pairing.host
        components.port = pairing.port
        components.path = "/"
        return components.url
    }

    private func failureReason(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                return "No network connection"
            case .cannotConnectToHost, .networkConnectionLost:
                return "Mac connection lost"
            case .timedOut:
                return "Connection timed out"
            default:
                break
            }
        }
        return "Connection lost"
    }
}
