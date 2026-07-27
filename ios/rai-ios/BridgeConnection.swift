import Foundation
import RaiCore
import UIKit

@MainActor
final class BridgeConnection: ObservableObject {
    enum Status: Equatable {
        case disconnected
        case connecting
        case connected(sessionName: String?)
        case reconnecting(attempt: Int)
        case failed(String)

        var label: String {
            switch self {
            case .disconnected: "Disconnected"
            case .connecting: "Connecting…"
            case let .connected(sessionName): sessionName.map { "Connected · \($0)" } ?? "Connected"
            case let .reconnecting(attempt): "Reconnecting · attempt \(attempt)"
            case let .failed(message): message
            }
        }

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    @Published private(set) var status: Status = .disconnected
    @Published private(set) var snapshot: SessionSnapshot?

    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var pairing: Pairing?
    private var reconnectAttempt = 0
    private var shouldReconnect = false
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func connect(to pairing: Pairing) {
        disconnect(clearPairing: false)
        self.pairing = pairing
        shouldReconnect = true
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
        openSocket()
    }

    func selectAndFocus(paneID: String) {
        Task {
            do {
                try await send(.selectPane(paneID: paneID))
                try await send(.focusPane(paneID: paneID))
            } catch {
                handleSocketFailure(error)
            }
        }
    }

    private func openSocket() {
        guard let pairing, let url = webSocketURL(for: pairing), shouldReconnect else {
            status = .failed("Invalid bridge address")
            return
        }

        reconnectTask?.cancel()
        status = reconnectAttempt == 0 ? .connecting : .reconnecting(attempt: reconnectAttempt)
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
                self.handleSocketFailure(error)
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
        case let .welcome(protocolVersion, sessionName):
            guard protocolVersion == bridgeProtocolVersion else {
                stopWithFailure("Unsupported bridge protocol \(protocolVersion)")
                return
            }
            reconnectAttempt = 0
            status = .connected(sessionName: sessionName)
        case let .authFailed(reason):
            stopWithFailure("Pairing rejected: \(reason)")
        case let .snapshot(snapshot):
            self.snapshot = snapshot
        case let .error(message):
            status = .failed(message)
        case .event, .paneOutput:
            break
        case .hello, .subscribe, .input, .focusPane, .selectPane, .resizePane:
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

    private func handleSocketFailure(_ error: Error) {
        guard shouldReconnect, !(error is CancellationError) else { return }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil || reconnectTask?.isCancelled == true else { return }
        task = nil
        receiveTask = nil
        reconnectAttempt += 1
        status = .reconnecting(attempt: reconnectAttempt)
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
        status = .failed(message)
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
        snapshot = nil
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
}
