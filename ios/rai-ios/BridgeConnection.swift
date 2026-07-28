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
    @Published private(set) var actionError: String?
    @Published private(set) var sessionName: String?
    var didConnect: (() -> Void)?
    var didReceiveBackgroundWork: (([PaneBackgroundWork]) -> Void)?

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
    private var paneScrollbackHandlers: [String: [UUID: (Data) -> Void]] = [:]
    // A seed can land before the terminal view has registered its handler
    // (openPane fires from onAppear, which can precede makeUIView). Hold the
    // payload and deliver it on registration instead of dropping it.
    private var pendingScrollback: [String: Data] = [:]
    private var desiredStreams: [String: (cols: Int, rows: Int)] = [:]
    // Panes whose scrollback seed actually arrived. Tracked separately from
    // desiredStreams so a seed lost to a dropped connection (opening a pane
    // while reconnecting is routine on a phone) is retried on the next
    // welcome instead of being skipped forever.
    private var seededPanes: Set<String> = []

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

    func clearActionError() {
        actionError = nil
    }

    func openPane(paneID: String, cols: Int = 80, rows: Int = 24) {
        let needsSeed = !seededPanes.contains(paneID)
        if desiredStreams[paneID] == nil {
            desiredStreams[paneID] = (cols, rows)
        }
        Task {
            do {
                try await send(.selectPane(paneID: paneID))
                try await send(.focusPane(paneID: paneID))
                // Read the size at send time, not at entry: the terminal's
                // layout often lands (and updates desiredStreams) between
                // openPane and this send, and the server drops resizes for
                // panes with no active stream — attaching with a stale size
                // would leave the stream permanently smaller than the view.
                let size = desiredStreams[paneID] ?? (cols, rows)
                if needsSeed {
                    // Sent before attachStream: the server handles messages in
                    // order, so history arrives before the first full frame.
                    try await send(
                        .readScrollback(paneID: paneID, lines: 1000, rows: size.rows)
                    )
                }
                try await send(
                    .attachStream(paneID: paneID, cols: size.cols, rows: size.rows)
                )
            } catch {
                handleSocketFailure(error)
            }
        }
    }

    func detachPane(paneID: String) {
        desiredStreams.removeValue(forKey: paneID)
        // Re-opening the pane later should seed fresh history again.
        seededPanes.remove(paneID)
        Task {
            do {
                try await send(.detachStream(paneID: paneID))
            } catch {
                handleSocketFailure(error)
            }
        }
    }

    func launchAgent(workspaceID: String?, agent: String, cwd: String? = nil) {
        sendAction(.launchAgent(workspaceID: workspaceID, agent: agent, cwd: cwd))
    }

    func renamePane(paneID: String, label: String) {
        sendAction(.renamePane(paneID: paneID, label: label))
    }

    func renameTab(tabID: String, label: String) {
        sendAction(.renameTab(tabID: tabID, label: label))
    }

    func closePane(paneID: String) {
        sendAction(.closePane(paneID: paneID))
    }

    func closeTab(tabID: String) {
        sendAction(.closeTab(tabID: tabID))
    }

    func renameWorkspace(workspaceID: String, label: String) {
        sendAction(.renameWorkspace(workspaceID: workspaceID, label: label))
    }

    func closeWorkspace(workspaceID: String) {
        sendAction(.closeWorkspace(workspaceID: workspaceID))
    }

    func broadcastInput(tabID: String, text: String) {
        sendAction(.broadcastInput(tabID: tabID, text: text))
    }

    private func sendAction(_ message: BridgeMessage) {
        Task {
            do {
                try await send(message)
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

    func addPaneScrollbackHandler(
        for paneID: String,
        handler: @escaping (Data) -> Void
    ) -> UUID {
        let id = UUID()
        paneScrollbackHandlers[paneID, default: [:]][id] = handler
        if let pending = pendingScrollback.removeValue(forKey: paneID) {
            handler(pending)
        }
        return id
    }

    func removePaneScrollbackHandler(for paneID: String, id: UUID) {
        paneScrollbackHandlers[paneID]?.removeValue(forKey: id)
        if paneScrollbackHandlers[paneID]?.isEmpty == true {
            paneScrollbackHandlers.removeValue(forKey: paneID)
        }
    }

    func sendKeys(_ keys: [String], to paneID: String) {
        sendAction(.sendKeys(paneID: paneID, keys: keys))
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

    func sendImage(_ data: Data, filename: String, to paneID: String) async throws {
        try await send(
            .sendImage(
                paneID: paneID,
                bytesBase64: data.base64EncodedString(),
                filename: filename
            )
        )
    }

    /// Notification actions can arrive while the app is suspended. Reuse the
    /// live socket when possible, otherwise reconnect and wait briefly for the
    /// authenticated welcome before sending within the notification window.
    func connectAndSendInput(
        _ bytes: [UInt8],
        to paneID: String,
        pairing: Pairing
    ) async -> Bool {
        if !status.isConnected {
            connect(to: pairing)
            for _ in 0..<80 {
                if status.isConnected { break }
                if requiresRepair { return false }
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return false }
            }
        }
        guard status.isConnected else { return false }
        do {
            try await send(
                .input(
                    paneID: paneID,
                    bytesBase64: Data(bytes).base64EncodedString()
                )
            )
            return true
        } catch {
            handleSocketFailure(error)
            return false
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
            // A message this client can't decode (e.g. a newer Mac added a
            // message type) must not kill the connection: throwing here would
            // reconnect, replay the same message, and loop forever. Skip it —
            // true incompatibility is caught by the welcome version check.
            do {
                handle(try decoder.decode(BridgeMessage.self, from: data))
            } catch {
                NSLog(
                    "rai-ios: skipping undecodable bridge message: %@",
                    String(describing: error)
                )
            }
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
            status = .connected
            self.sessionName = sessionName
            didConnect?()
            for (paneID, size) in desiredStreams {
                let needsSeed = !seededPanes.contains(paneID)
                Task {
                    do {
                        if needsSeed {
                            try await send(
                                .readScrollback(
                                    paneID: paneID,
                                    lines: 1000,
                                    rows: size.rows
                                )
                            )
                        }
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
        case let .backgroundWork(work):
            didReceiveBackgroundWork?(work)
        case let .paneFrame(paneID, bytesBase64, full, _):
            guard let data = Data(base64Encoded: bytesBase64) else { return }
            guard let handlers = paneFrameHandlers[paneID]?.values else { return }
            for handler in handlers {
                handler(data, full)
            }
        case let .scrollback(paneID, bytesBase64):
            seededPanes.insert(paneID)
            guard let data = Data(base64Encoded: bytesBase64), !data.isEmpty else { return }
            guard let handlers = paneScrollbackHandlers[paneID]?.values,
                  !handlers.isEmpty else {
                pendingScrollback[paneID] = data
                return
            }
            for handler in handlers {
                handler(data)
            }
        case let .error(message):
            if message.hasPrefix("Invalid bridge message")
                || message.hasPrefix("Could not read scrollback") {
                // Old Mac that predates readScrollback, or a transient history
                // read failure. Scrollback is progressive enhancement; don't
                // drop or flag a healthy connection over it.
                NSLog("rai-ios: scrollback unavailable: %@", message)
            } else if Self.isActionError(message) {
                actionError = message
            } else {
                status = .failed(reason: message)
            }
        case .event:
            break
        case .hello, .subscribe, .attachStream, .detachStream,
             .input, .sendImage, .focusPane, .selectPane, .resizePane,
             .launchAgent, .renamePane, .renameTab, .closePane, .closeTab,
             .registerPush, .unregisterPush, .readScrollback,
             .renameWorkspace, .closeWorkspace, .broadcastInput, .sendKeys,
             .listSessions, .selectSession, .sessions:
            break
        }
    }

    private static func isActionError(_ message: String) -> Bool {
        message == "Agent must be claude or codex."
            || message.hasPrefix("Unknown workspace ")
            || message.hasPrefix("Could not launch ")
            || message.hasPrefix("Could not rename ")
            || message.hasPrefix("Could not close ")
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
        NSLog("rai-ios: connection lost, will reconnect: %@", String(describing: error))
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
        sessionName = nil
        didReceiveBackgroundWork?([])
        desiredStreams.removeAll()
        seededPanes.removeAll()
        if clearPairing { pairing = nil }
    }

    private func webSocketURL(for pairing: Pairing) -> URL? {
        var components = URLComponents()
        components.scheme = pairing.useTLS ? "wss" : "ws"
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
