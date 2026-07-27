import Foundation
import Network
import RaiCore

/// Token-authenticated WebSocket bridge from companion devices to RaiModel's
/// current herdr session.
///
/// The bridge intentionally uses cleartext WebSocket on a trusted LAN or Tailscale
/// network. The pairing token prevents accidental access, but is not a
/// substitute for transport encryption on an untrusted network.
@MainActor
final class RaiBridgeServer: ObservableObject {
    // 8787 collided with common dev servers (e.g. bun); 47837 is an uncommon
    // registered-range port far from the usual suspects.
    static let defaultPort: UInt16 = 47837

    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var connectedDeviceCount = 0
    @Published private(set) var pairingToken: String

    var isEnabled: Bool {
        get { userDefaults.bool(forKey: Self.enabledKey) }
        set {
            userDefaults.set(newValue, forKey: Self.enabledKey)
            newValue ? start() : stop()
        }
    }

    var displayHost: String {
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return name.hasSuffix(".local") ? name : "\(name).local"
    }

    var port: UInt16 { Self.defaultPort }

    var pairingURL: URL? {
        var components = URLComponents()
        components.scheme = "rai"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "host", value: displayHost),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "token", value: pairingToken),
        ]
        return components.url
    }

    private static let enabledKey = "companionBridgeEnabled"
    private static let tokenKey = "companionBridgePairingToken"
    private unowned let model: RaiModel
    private let userDefaults: UserDefaults
    private let queue = DispatchQueue(label: "ai.sawmills.rai.bridge")
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: BridgeClient] = [:]
    private var observeStreams: [ObjectIdentifier: [String: ObserveStream]] = [:]

    init(model: RaiModel, userDefaults: UserDefaults = .standard) {
        self.model = model
        self.userDefaults = userDefaults
        if let saved = userDefaults.string(forKey: Self.tokenKey), !saved.isEmpty {
            pairingToken = saved
        } else {
            let token = Self.makeToken()
            pairingToken = token
            userDefaults.set(token, forKey: Self.tokenKey)
        }
    }

    func startIfEnabled() {
        if isEnabled {
            start()
        }
    }

    func start() {
        guard listener == nil else { return }
        do {
            let webSocket = NWProtocolWebSocket.Options()
            webSocket.autoReplyPing = true
            let parameters = NWParameters.tcp
            parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                statusMessage = "Invalid bridge port \(port)."
                return
            }
            let listener = try NWListener(using: parameters, on: nwPort)
            listener.service = NWListener.Service(name: "rai", type: "_rai._tcp")
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.listenerDidChange(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            statusMessage = error.localizedDescription
            isRunning = false
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        stopAllObserveStreams()
        for client in clients.values {
            client.connection.cancel()
        }
        clients.removeAll()
        connectedDeviceCount = 0
        isRunning = false
    }

    func regenerateToken() {
        pairingToken = Self.makeToken()
        userDefaults.set(pairingToken, forKey: Self.tokenKey)
        // Authentication is connection-scoped, so changing the token also
        // disconnects already-paired devices immediately.
        stopAllObserveStreams()
        for client in clients.values {
            client.connection.cancel()
        }
        clients.removeAll()
        connectedDeviceCount = 0
    }

    func relay(events: [HerdrEvent]) {
        let subscribers = clients.values.filter(\.isSubscribed)
        guard !subscribers.isEmpty else { return }

        for event in events
        where event.name != "pane.output_changed" && event.name != "pane.updated" {
            // Structural event details are useful for diagnostics. The
            // authoritative state follows as a fresh snapshot from RaiModel.
            broadcast(
                .event(BridgeEvent(name: event.name, payload: event.data)),
                onlyToSubscribers: true
            )
        }
    }

    func relay(snapshot: SessionSnapshot) {
        broadcast(.snapshot(snapshot), onlyToSubscribers: true)
    }

    private func listenerDidChange(_ state: NWListener.State) {
        switch state {
        case .ready:
            isRunning = true
            statusMessage = nil
        case .failed(let error):
            statusMessage = error.localizedDescription
            stop()
        case .cancelled:
            isRunning = false
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let client = BridgeClient(connection: connection)
        let id = ObjectIdentifier(connection)
        clients[id] = client
        connection.stateUpdateHandler = { [weak self] state in
            guard case .failed = state else {
                if case .cancelled = state {
                    Task { @MainActor in self?.removeClient(id) }
                }
                return
            }
            Task { @MainActor in self?.removeClient(id) }
        }
        connection.start(queue: queue)
        receive(from: client)
    }

    private func receive(from client: BridgeClient) {
        client.connection.receiveMessage { [weak self, weak client] data, context, _, error in
            guard let self, let client else { return }
            Task { @MainActor in
                guard self.clients[ObjectIdentifier(client.connection)] != nil else { return }
                if let error {
                    self.removeClient(ObjectIdentifier(client.connection))
                    self.statusMessage = error.localizedDescription
                    return
                }
                if let data,
                   let metadata = context?.protocolMetadata(
                       definition: NWProtocolWebSocket.definition
                   ) as? NWProtocolWebSocket.Metadata,
                   metadata.opcode == .text {
                    await self.handle(data, from: client)
                } else {
                    self.send(.error(message: "Only WebSocket text frames are supported."), to: client)
                }
                if self.clients[ObjectIdentifier(client.connection)] != nil {
                    self.receive(from: client)
                }
            }
        }
    }

    private func handle(_ data: Data, from client: BridgeClient) async {
        let message: BridgeMessage
        do {
            message = try JSONDecoder().decode(BridgeMessage.self, from: data)
        } catch {
            send(.error(message: "Invalid bridge message: \(error.localizedDescription)"), to: client)
            return
        }

        if !client.isAuthenticated {
            guard case let .hello(token, info) = message else {
                reject(client, reason: "hello must be the first message")
                return
            }
            guard token == pairingToken else {
                reject(client, reason: "Invalid pairing token")
                return
            }
            client.isAuthenticated = true
            client.info = info
            updateConnectedDeviceCount()
            send(
                .welcome(
                    protocolVersion: bridgeProtocolVersion,
                    sessionName: model.currentSessionName
                ),
                to: client
            )
            return
        }

        switch message {
        case .subscribe:
            client.isSubscribed = true
            if let snapshot = model.snapshot {
                send(.snapshot(snapshot), to: client)
            } else {
                send(.error(message: "Herdr is not connected."), to: client)
            }
        case let .attachStream(paneID, cols, rows):
            guard client.isSubscribed else {
                send(.error(message: "Subscribe before attaching a pane stream."), to: client)
                return
            }
            guard cols > 0, rows > 0 else {
                send(.error(message: "Pane dimensions must be positive."), to: client)
                return
            }
            startObserveStream(paneID: paneID, cols: cols, rows: rows, for: client)
        case let .detachStream(paneID):
            stopObserveStream(paneID: paneID, for: client)
        case let .input(paneID, bytesBase64):
            guard let data = Data(base64Encoded: bytesBase64) else {
                send(.error(message: "input bytesBase64 is invalid."), to: client)
                return
            }
            await perform(for: client) {
                try await self.model.client.sendInput(paneID: paneID, bytes: [UInt8](data))
            }
        case let .focusPane(paneID):
            await perform(for: client) {
                try await self.model.client.focusPane(paneID)
            }
        case let .selectPane(paneID):
            guard model.snapshot?.panes.contains(where: { $0.paneID == paneID }) == true else {
                send(.error(message: "Unknown pane \(paneID)."), to: client)
                return
            }
            model.select(paneID: paneID, focusInHerdr: true)
        case let .resizePane(paneID, cols, rows):
            guard cols > 0, rows > 0 else {
                send(.error(message: "Pane dimensions must be positive."), to: client)
                return
            }
            let clientID = ObjectIdentifier(client.connection)
            guard observeStreams[clientID]?[paneID] != nil else { return }
            startObserveStream(paneID: paneID, cols: cols, rows: rows, for: client)
        case .hello:
            send(.error(message: "Connection is already authenticated."), to: client)
        case .welcome, .authFailed, .snapshot, .event, .paneFrame, .error:
            send(.error(message: "Server-to-client message received from client."), to: client)
        }
    }

    private func startObserveStream(
        paneID: String,
        cols: Int,
        rows: Int,
        for client: BridgeClient
    ) {
        guard model.snapshot?.panes.contains(where: { $0.paneID == paneID }) == true else {
            send(.error(message: "Unknown pane \(paneID)."), to: client)
            return
        }

        stopObserveStream(paneID: paneID, for: client)

        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: HerdrCLI.binaryPath)
        process.arguments = [
            "terminal", "session", "observe", paneID,
            "--cols", String(cols), "--rows", String(rows),
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        let stream = ObserveStream(process: process, stdout: stdout)
        let clientID = ObjectIdentifier(client.connection)

        stdout.fileHandleForReading.readabilityHandler = { [weak self, weak client, weak stream] handle in
            guard let self, let client, let stream else { return }
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let frames = stream.consume(data)
            guard !frames.isEmpty else { return }
            Task { @MainActor in
                guard self.observeStreams[clientID]?[paneID] === stream else { return }
                for frame in frames {
                    self.send(
                        .paneFrame(
                            paneID: paneID,
                            bytesBase64: frame.bytes,
                            full: frame.full,
                            seq: frame.seq
                        ),
                        to: client
                    )
                }
            }
        }
        process.terminationHandler = { [weak self, weak client, weak stream] process in
            Task { @MainActor in
                guard let self, let client, let stream,
                      self.observeStreams[clientID]?[paneID] === stream
                else { return }
                self.removeObserveStream(paneID: paneID, clientID: clientID)
                if !stream.isStopping {
                    self.send(
                        .error(
                            message: "Pane stream \(paneID) exited with status \(process.terminationStatus)."
                        ),
                        to: client
                    )
                }
            }
        }

        observeStreams[clientID, default: [:]][paneID] = stream
        do {
            try process.run()
        } catch {
            removeObserveStream(paneID: paneID, clientID: clientID)
            send(
                .error(message: "Unable to start pane stream \(paneID): \(error.localizedDescription)"),
                to: client
            )
        }
    }

    private func stopObserveStream(paneID: String, for client: BridgeClient) {
        let clientID = ObjectIdentifier(client.connection)
        guard let stream = observeStreams[clientID]?[paneID] else { return }
        stream.stop()
        removeObserveStream(paneID: paneID, clientID: clientID)
    }

    private func removeObserveStream(paneID: String, clientID: ObjectIdentifier) {
        guard let stream = observeStreams[clientID]?.removeValue(forKey: paneID) else { return }
        stream.close()
        if observeStreams[clientID]?.isEmpty == true {
            observeStreams.removeValue(forKey: clientID)
        }
    }

    private func stopObserveStreams(for clientID: ObjectIdentifier) {
        guard let streams = observeStreams.removeValue(forKey: clientID) else { return }
        for stream in streams.values {
            stream.stop()
            stream.close()
        }
    }

    private func stopAllObserveStreams() {
        let streams = observeStreams.values.flatMap(\.values)
        observeStreams.removeAll()
        for stream in streams {
            stream.stop()
            stream.close()
        }
    }

    private func perform(
        for client: BridgeClient,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
        } catch {
            send(.error(message: error.localizedDescription), to: client)
        }
    }

    private func reject(_ client: BridgeClient, reason: String) {
        send(.authFailed(reason: reason), to: client) {
            client.connection.cancel()
        }
    }

    private func broadcast(_ message: BridgeMessage, onlyToSubscribers: Bool) {
        for client in clients.values
        where !onlyToSubscribers || client.isSubscribed {
            send(message, to: client)
        }
    }

    private func send(
        _ message: BridgeMessage,
        to client: BridgeClient,
        completion: (() -> Void)? = nil
    ) {
        do {
            let data = try JSONEncoder().encode(message)
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(
                identifier: "rai.bridge.message",
                metadata: [metadata]
            )
            client.connection.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { _ in
                    if let completion {
                        Task { @MainActor in completion() }
                    }
                }
            )
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func removeClient(_ id: ObjectIdentifier) {
        stopObserveStreams(for: id)
        clients.removeValue(forKey: id)
        updateConnectedDeviceCount()
    }

    private func updateConnectedDeviceCount() {
        connectedDeviceCount = clients.values.lazy.filter(\.isAuthenticated).count
    }

    private static func makeToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

private struct ObserveFrame: Decodable {
    let type: String
    let encoding: String
    let seq: Int
    let full: Bool
    let bytes: String
}

private final class ObserveStream: @unchecked Sendable {
    let process: Process
    let stdout: Pipe
    private var buffer = Data()
    private(set) var isStopping = false

    init(process: Process, stdout: Pipe) {
        self.process = process
        self.stdout = stdout
    }

    func consume(_ data: Data) -> [ObserveFrame] {
        buffer.append(data)
        var frames: [ObserveFrame] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let frame = try? JSONDecoder().decode(ObserveFrame.self, from: line),
                  frame.type == "terminal.frame",
                  frame.encoding == "ansi"
            else { continue }
            frames.append(frame)
        }
        return frames
    }

    @MainActor
    func stop() {
        isStopping = true
        stdout.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
        }
    }

    @MainActor
    func close() {
        stdout.fileHandleForReading.readabilityHandler = nil
        try? stdout.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
    }
}

private final class BridgeClient: @unchecked Sendable {
    let connection: NWConnection
    var isAuthenticated = false
    var isSubscribed = false
    var info: ClientInfo?

    init(connection: NWConnection) {
        self.connection = connection
    }
}
