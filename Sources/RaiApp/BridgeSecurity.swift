import CryptoKit
import Foundation
import RaiCore
import Security

struct BridgePairingCode: Equatable {
    let value: String
    let expiresAt: Date
    let failedAttempts: Int
}

struct BridgePairedDevice: Codable, Equatable, Identifiable {
    let id: String
    let label: String
    let tokenHash: Data
    let createdAt: Date
    var lastSeen: Date
    var pushPreferences: PushPreferences

    init(
        id: String,
        label: String,
        tokenHash: Data,
        createdAt: Date,
        lastSeen: Date,
        pushPreferences: PushPreferences = .default
    ) {
        self.id = id
        self.label = label
        self.tokenHash = tokenHash
        self.createdAt = createdAt
        self.lastSeen = lastSeen
        self.pushPreferences = pushPreferences
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, tokenHash, createdAt, lastSeen, pushPreferences
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        tokenHash = try container.decode(Data.self, forKey: .tokenHash)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastSeen = try container.decode(Date.self, forKey: .lastSeen)
        pushPreferences = try container.decodeIfPresent(
            PushPreferences.self,
            forKey: .pushPreferences
        ) ?? .default
    }
}

enum BridgePairingFailure: Error, Equatable {
    case invalidOrExpired
    case entropyUnavailable
}

struct BridgePairingSuccess: Equatable {
    let token: String
    let device: BridgePairedDevice
}

final class BridgeDeviceCredentialStore {
    typealias RandomBytes = (Int) throws -> [UInt8]

    private struct PendingPairing {
        let clientHash: Data
        let device: BridgePairedDevice
    }

    static let codeTTL: TimeInterval = 10 * 60
    static let maximumFailedAttempts = 5
    static let codeAlphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")

    private static let devicesKey = "companionBridgePairedDevicesV1"

    private let defaults: UserDefaults
    private let now: () -> Date
    private let randomBytes: RandomBytes
    private(set) var pairingCode: BridgePairingCode?
    private(set) var devices: [BridgePairedDevice]
    private var pendingPairing: PendingPairing?

    init(
        defaults: UserDefaults,
        now: @escaping () -> Date = Date.init,
        randomBytes: @escaping RandomBytes = BridgeDeviceCredentialStore.secureRandomBytes,
        mintInitialCode: Bool = true
    ) {
        self.defaults = defaults
        self.now = now
        self.randomBytes = randomBytes
        if let data = defaults.data(forKey: Self.devicesKey),
           let saved = try? JSONDecoder().decode([BridgePairedDevice].self, from: data) {
            devices = saved
        } else {
            devices = []
        }
        if mintInitialCode {
            pairingCode = try? makePairingCode()
        }
    }

    @discardableResult
    func regeneratePairingCode() -> BridgePairingCode? {
        pendingPairing = nil
        pairingCode = try? makePairingCode()
        return pairingCode
    }

    func invalidatePairingCode() {
        pairingCode = nil
        pendingPairing = nil
    }

    func validPairingCode(at date: Date? = nil) -> BridgePairingCode? {
        guard let pairingCode else { return nil }
        guard pairingCode.expiresAt > (date ?? now()) else {
            self.pairingCode = nil
            pendingPairing = nil
            return nil
        }
        return pairingCode
    }

    func exchange(code candidate: String, client: ClientInfo) -> Result<BridgePairingSuccess, BridgePairingFailure> {
        guard let active = validPairingCode() else {
            return .failure(.invalidOrExpired)
        }
        guard candidate.utf8.count <= 64 else {
            recordFailedAttempt(for: active)
            return .failure(.invalidOrExpired)
        }
        let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalized == active.value else {
            recordFailedAttempt(for: active)
            return .failure(.invalidOrExpired)
        }

        let clientHash = Self.hash(client.deviceID)
        if let pendingPairing,
           !Self.constantTimeEqual(clientHash, pendingPairing.clientHash) {
            recordFailedAttempt(for: active)
            return .failure(.invalidOrExpired)
        }

        let token: String
        do {
            token = try makeBearerToken()
        } catch {
            return .failure(.entropyUnavailable)
        }
        let tokenHash = Self.hash(token)
        let device: BridgePairedDevice
        if let pendingPairing {
            device = BridgePairedDevice(
                id: pendingPairing.device.id,
                label: pendingPairing.device.label,
                tokenHash: tokenHash,
                createdAt: pendingPairing.device.createdAt,
                lastSeen: pendingPairing.device.lastSeen,
                pushPreferences: pendingPairing.device.pushPreferences
            )
        } else {
            let date = now()
            device = BridgePairedDevice(
                id: UUID().uuidString,
                label: Self.deviceLabel(client),
                tokenHash: tokenHash,
                createdAt: date,
                lastSeen: date
            )
        }
        pendingPairing = PendingPairing(clientHash: clientHash, device: device)
        return .success(BridgePairingSuccess(token: token, device: device))
    }

    func authenticate(token: String) -> BridgePairedDevice? {
        let tokenCharacters = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        )
        guard token.utf8.count == 43,
              token.unicodeScalars.allSatisfy(tokenCharacters.contains)
        else { return nil }
        let candidateHash = Self.hash(token)
        var matchedIndex: Int?
        for index in devices.indices {
            let matches = Self.constantTimeEqual(candidateHash, devices[index].tokenHash)
            if matches, matchedIndex == nil {
                matchedIndex = index
            }
        }
        _ = validPairingCode()
        let pendingMatches = pendingPairing.map {
            Self.constantTimeEqual(candidateHash, $0.device.tokenHash)
        } ?? false
        if pendingMatches, var device = pendingPairing?.device {
            device.lastSeen = now()
            devices.append(device)
            devices.sort { $0.createdAt < $1.createdAt }
            persistDevices()
            pairingCode = nil
            pendingPairing = nil
            return device
        }
        guard let matchedIndex else { return nil }
        devices[matchedIndex].lastSeen = now()
        persistDevices()
        return devices[matchedIndex]
    }

    @discardableResult
    func revoke(deviceID: String) -> Bool {
        let oldCount = devices.count
        devices.removeAll { $0.id == deviceID }
        guard devices.count != oldCount else { return false }
        persistDevices()
        return true
    }

    @discardableResult
    func updatePushPreferences(
        _ preferences: PushPreferences,
        deviceID: String
    ) -> BridgePairedDevice? {
        guard let index = devices.firstIndex(where: { $0.id == deviceID }) else { return nil }
        devices[index].pushPreferences = preferences
        persistDevices()
        return devices[index]
    }

    static func hash(_ token: String) -> Data {
        Data(SHA256.hash(data: Data(token.utf8)))
    }

    static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        let left = [UInt8](lhs)
        let right = [UInt8](rhs)
        let count = max(left.count, right.count)
        var difference = UInt64(left.count ^ right.count)
        for index in 0..<count {
            let leftByte = index < left.count ? left[index] : 0
            let rightByte = index < right.count ? right[index] : 0
            difference |= UInt64(leftByte ^ rightByte)
        }
        return difference == 0
    }

    private func makePairingCode() throws -> BridgePairingCode {
        let bytes = try randomBytes(8)
        guard bytes.count == 8 else { throw BridgePairingFailure.entropyUnavailable }
        let value = String(bytes.map { Self.codeAlphabet[Int($0 & 31)] })
        return BridgePairingCode(
            value: value,
            expiresAt: now().addingTimeInterval(Self.codeTTL),
            failedAttempts: 0
        )
    }

    private func makeBearerToken() throws -> String {
        let bytes = try randomBytes(32)
        guard bytes.count == 32 else { throw BridgePairingFailure.entropyUnavailable }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func recordFailedAttempt(for active: BridgePairingCode) {
        let failures = active.failedAttempts + 1
        pairingCode = failures >= Self.maximumFailedAttempts
            ? nil
            : BridgePairingCode(
                value: active.value,
                expiresAt: active.expiresAt,
                failedAttempts: failures
            )
        if pairingCode == nil {
            pendingPairing = nil
        }
    }

    private func persistDevices() {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        defaults.set(data, forKey: Self.devicesKey)
    }

    private static func secureRandomBytes(count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else { throw BridgePairingFailure.entropyUnavailable }
        return bytes
    }

    private static func deviceLabel(_ client: ClientInfo) -> String {
        let name = printablePrefix(client.name, limit: 80)
        let model = printablePrefix(client.model ?? "", limit: 40)
        if !model.isEmpty, name.localizedCaseInsensitiveContains(model) == false {
            return printablePrefix("\(name) · \(model)", limit: 100)
        }
        return name.isEmpty ? (model.isEmpty ? "iPhone" : model) : name
    }

    private static func printablePrefix(_ value: String, limit: Int) -> String {
        let filtered = value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
                && !CharacterSet.illegalCharacters.contains($0)
        }
        return String(String.UnicodeScalarView(filtered)).trimmingCharacters(in: .whitespacesAndNewlines)
            .prefixString(limit)
    }
}

@MainActor
final class BridgeLiveConnectionRegistry {
    private struct Entry {
        let deviceID: String
        let revoke: () -> Void
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    var connectedDeviceCount: Int {
        Set(entries.values.map(\.deviceID)).count
    }

    func register(id: ObjectIdentifier, deviceID: String, revoke: @escaping () -> Void) {
        entries[id] = Entry(deviceID: deviceID, revoke: revoke)
    }

    func remove(id: ObjectIdentifier) {
        entries.removeValue(forKey: id)
    }

    @discardableResult
    func revoke(deviceID: String) -> [ObjectIdentifier] {
        let matches = entries.filter { $0.value.deviceID == deviceID }
        for (id, entry) in matches {
            entries.removeValue(forKey: id)
            entry.revoke()
        }
        return Array(matches.keys)
    }

    func removeAll() {
        entries.removeAll()
    }
}

enum BridgeAuditContent: Equatable, Encodable {
    case text(String)
    case bytes(Int)
    case none

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .text(value): try container.encode(value)
        case let .bytes(count): try container.encode(count)
        case .none: try container.encodeNil()
        }
    }
}

struct BridgeAuditEvent: Equatable {
    let action: String
    let targetIDs: [String: String]
    let content: BridgeAuditContent

    init?(_ message: BridgeMessage) {
        switch message {
        case let .input(paneID, bytesBase64):
            self.init(
                action: "input",
                targets: ["pane_id": paneID],
                bytes: Data(base64Encoded: bytesBase64)
            )
        case let .sendKeys(paneID, keys):
            self.init(action: "sendKeys", targets: ["pane_id": paneID], text: keys.joined(separator: " "))
        case let .decide(paneID, requestID, decision):
            self.init(
                action: "decide",
                targets: ["pane_id": paneID, "request_id": requestID],
                text: decision.rawValue
            )
        case let .sendImage(paneID, bytesBase64, _):
            self.init(
                action: "sendImage",
                targets: ["pane_id": paneID],
                content: .bytes(Data(base64Encoded: bytesBase64)?.count ?? 0)
            )
        case let .focusPane(paneID):
            self.init(action: "focusPane", targets: ["pane_id": paneID])
        case let .selectPane(paneID):
            self.init(action: "selectPane", targets: ["pane_id": paneID])
        case let .resizePane(paneID, _, _):
            self.init(action: "resizePane", targets: ["pane_id": paneID])
        case let .launchAgent(workspaceID, agent, cwd):
            var targets: [String: String] = [:]
            if let workspaceID { targets["workspace_id"] = workspaceID }
            let detail = cwd.map { "\(agent) \($0)" } ?? agent
            self.init(action: "launchAgent", targets: targets, text: detail)
        case let .renamePane(paneID, label):
            self.init(action: "renamePane", targets: ["pane_id": paneID], text: label)
        case let .renameTab(tabID, label):
            self.init(action: "renameTab", targets: ["tab_id": tabID], text: label)
        case let .closePane(paneID):
            self.init(action: "closePane", targets: ["pane_id": paneID])
        case let .closeTab(tabID):
            self.init(action: "closeTab", targets: ["tab_id": tabID])
        case .registerPush:
            self.init(action: "registerPush")
        case .unregisterPush:
            self.init(action: "unregisterPush")
        case let .renameWorkspace(workspaceID, label):
            self.init(action: "renameWorkspace", targets: ["workspace_id": workspaceID], text: label)
        case let .closeWorkspace(workspaceID, connectionID):
            self.init(action: "closeWorkspace", targets: ["workspace_id": workspaceID, "connection_id": connectionID ?? "unverified"])
        case let .closeWorkspaceGroup(workspaceID, expectedWorkspaceIDs, connectionID):
            self.init(action: "closeWorkspaceGroup", targets: [
                "workspace_id": workspaceID, "workspace_ids": expectedWorkspaceIDs.joined(separator: ","),
                "connection_id": connectionID
            ])
        case let .broadcastInput(tabID, text):
            self.init(action: "broadcastInput", targets: ["tab_id": tabID], text: text)
        case let .notificationAction(request):
            self.init(action: "notificationAction", targets: ["connection_id": request.connectionID, "pane_id": request.paneID])
        case let .machineRequest(request):
            self.init(action: "machineRequest", targets: ["request_id": request.id.uuidString,
                "catalog_revision": request.revision.uuidString])
        case let .endpointRequest(request):
            var targets = ["connection_id": request.identity.connectionID,
                           "view_id": request.identity.viewID.uuidString, "request_id": request.requestID]
            switch request.operation {
            case .popupInput(let terminalID, let input):
                targets["terminal_id"] = terminalID
                self.init(action: "endpoint.popupInput", targets: targets, content: .bytes((try? input.input().byteCount) ?? 0))
            case .input(let paneID, let input):
                targets["pane_id"] = paneID
                self.init(action: "endpoint.input", targets: targets, content: .bytes((try? input.input().byteCount) ?? 0))
            case .terminalAction(let action):
                targets["pane_id"] = action.paneID
                self.init(action: action.historyRPC == nil ? "endpoint.agent.prompt" : "endpoint.pane.selection.read", targets: targets)
            case .plugin(let plugin): self.init(plugin: plugin, targets: targets)
            case .layout(let layout):
                targets["workspace_id"] = layout.workspaceID
                targets["tab_id"] = layout.tabID
                self.init(action: "endpoint." + layout.action.method, targets: targets)
            case .launchAgent(let launch):
                targets["pane_id"] = launch.paneID
                targets["boot_id"] = launch.bootID
                targets["kind"] = launch.kind.rawValue
                self.init(action: "endpoint.launchAgent", targets: targets)
            case .worktree(let worktree):
                targets["workspace_id"] = worktree.operation.rpc.params["workspace_id"]?.stringValue
                self.init(action: "endpoint." + worktree.operation.rpc.method, targets: targets)
            case .command(let command):
                let rpc = command.rpc
                for key in ["pane_id", "tab_id", "workspace_id", "target_pane_id", "source_workspace_id"] {
                    if let value = rpc.params[key]?.stringValue { targets[key] = value }
                }
                self.init(action: "endpoint." + rpc.method, targets: targets)
            case .open: self.init(action: "endpoint.open", targets: targets)
            case .close: self.init(action: "endpoint.close", targets: targets)
            case .resize: self.init(action: "endpoint.resize", targets: targets)
            }
        case let .manageHerdr(request):
            self.init(action: request.action.rawValue, targets: [
                "connection_id": request.connectionID, "request_id": request.id
            ])
        case let .selectSession(name):
            self.init(action: "selectSession", targets: ["session": name])
        case .pushPrefs:
            self.init(action: "pushPrefs")
        case .pair, .hello, .subscribe, .attachStream, .detachStream, .readScrollback,
             .history, .historyReceived, .decisionAvailability,
             .listSessions, .paired, .welcome, .authFailed, .snapshot, .event,
             .paneFrame, .scrollback, .scrollbackUnchanged, .backgroundWork, .sessions, .historyPage,
             .historyError, .pushPrefsState, .error, .paneError, .decisionResult, .explainAgent, .agentExplanation,
             .herdrManagementResult, .endpointState, .machineState:
            return nil
        }
    }

    private init(plugin: EndpointPluginRequest, targets: [String: String]) {
        var targets = targets
        targets["plugin_request_id"] = plugin.id.uuidString
        let action: String
        switch plugin.operation {
        case .list: action = "plugin.list"
        case .enable(let id): action = "plugin.enable"; targets["plugin_id"] = id
        case .disable(let id): action = "plugin.disable"; targets["plugin_id"] = id
        case .unlink(let id): action = "plugin.unlink"; targets["plugin_id"] = id
        case .uninstall(let id): action = "plugin.uninstall"; targets["plugin_id"] = id
        case .integrations: action = "integration.list"
        case .installIntegration(let target): action = "integration.install"; targets["integration"] = target
        case .setAgentView: action = "agent.view.set"
        case .clearAgentView: action = "agent.view.clear"
        case .activateLink(let link): action = "pane.link.activate"; targets["pane_id"] = link.paneID
        case .openPane(let pane):
            action = "plugin.pane.open"
            targets["plugin_id"] = pane.pluginID; targets["entrypoint"] = pane.entrypoint
            targets["pane_id"] = pane.paneID
        case .prepareInstall: action = "plugin.install.review"
        case .confirmInstall(let id): action = "plugin.install.confirm"; targets["preview_id"] = id.uuidString
        case .cancelInstall(let id): action = "plugin.install.cancel"; targets["preview_id"] = id.uuidString
        }
        self.init(action: "endpoint." + action, targets: targets)
    }

    private init(
        action: String,
        targets: [String: String] = [:],
        text: String? = nil,
        bytes: Data? = nil,
        content: BridgeAuditContent? = nil
    ) {
        self.action = action
        targetIDs = targets.mapValues { $0.prefixString(200) }
        if let content {
            self.content = content
        } else if let bytes {
            self.content = Self.content(for: bytes)
        } else if let text {
            self.content = Self.content(for: Data(text.utf8))
        } else {
            self.content = .none
        }
    }

    private static func content(for data: Data) -> BridgeAuditContent {
        // The audit contract keeps the first 200 printable characters.
        // Pair and hello messages never create audit events.
        guard var text = String(data: data, encoding: .utf8) else {
            return .bytes(data.count)
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        guard !text.isEmpty else { return .bytes(data.count) }
        let isPrintable = text.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
                && !CharacterSet.illegalCharacters.contains($0)
        }
        return isPrintable ? .text(text.prefixString(200)) : .bytes(data.count)
    }
}

final class BridgeAuditLogger: @unchecked Sendable {
    typealias WriteOperation = @Sendable (Data) throws -> Void

    static let maximumBytes = 10 * 1_024 * 1_024
    static let maximumPendingWrites = 1_024

    let fileURL: URL
    private let now: () -> Date
    private let queue = DispatchQueue(label: "ai.sawmills.rai.bridge-audit", qos: .utility)
    private let stateLock = NSLock()
    private let writeOperation: WriteOperation
    private let maximumPendingWrites: Int
    private var healthy = true
    private var pendingWrites = 0
    private var failureHandler: (@Sendable (String) -> Void)?

    init(
        fileURL: URL = BridgeAuditLogger.defaultURL,
        maximumBytes: Int = BridgeAuditLogger.maximumBytes,
        now: @escaping () -> Date = Date.init,
        fileManager: FileManager = .default
    ) throws {
        self.fileURL = fileURL
        self.now = now
        self.maximumPendingWrites = Self.maximumPendingWrites
        let writer = BridgeAuditFileWriter(
            fileURL: fileURL,
            maximumBytes: maximumBytes,
            fileManager: fileManager
        )
        try writer.prepare()
        writeOperation = { data in try writer.append(data) }
    }

    init(
        fileURL: URL,
        now: @escaping () -> Date = Date.init,
        maximumPendingWrites: Int = BridgeAuditLogger.maximumPendingWrites,
        writeOperation: @escaping WriteOperation
    ) {
        self.fileURL = fileURL
        self.now = now
        self.maximumPendingWrites = maximumPendingWrites
        self.writeOperation = writeOperation
    }

    var isHealthy: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return healthy
    }

    func setFailureHandler(_ handler: @escaping @Sendable (String) -> Void) {
        stateLock.lock()
        failureHandler = handler
        stateLock.unlock()
    }

    @discardableResult
    func enqueue(
        deviceID: String,
        deviceLabel: String,
        event: BridgeAuditEvent
    ) -> Bool {
        guard isHealthy else { return false }
        let entry = BridgeAuditEntry(
            ts: Self.timestamp(now()),
            deviceID: deviceID,
            device: deviceLabel.prefixString(100),
            action: event.action,
            targetIDs: event.targetIDs,
            content: event.content
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            var encoded = try encoder.encode(entry)
            encoded.append(0x0A)
            data = encoded
        } catch {
            recordFailure(error)
            return false
        }

        stateLock.lock()
        guard healthy, pendingWrites < maximumPendingWrites else {
            stateLock.unlock()
            return false
        }
        pendingWrites += 1
        // Queue admission lets the current input continue without waiting for fsync.
        // A failed write closes admission before later inputs can join the queue.
        queue.async { [self] in
            defer { completePendingWrite() }
            do {
                try writeOperation(data)
            } catch {
                recordFailure(error)
            }
        }
        stateLock.unlock()
        return true
    }

    func flush() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: isHealthy)
            }
        }
    }

    private func recordFailure(_ error: Error) {
        let handler: (@Sendable (String) -> Void)?
        stateLock.lock()
        if healthy {
            healthy = false
            handler = failureHandler
        } else {
            handler = nil
        }
        stateLock.unlock()
        handler?(error.localizedDescription)
    }

    private func completePendingWrite() {
        stateLock.lock()
        pendingWrites -= 1
        stateLock.unlock()
    }

    static var defaultURL: URL {
        AppDataPaths.current.applicationSupport
            .appendingPathComponent("bridge-audit.jsonl")
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

private final class BridgeAuditFileWriter: @unchecked Sendable {
    private let fileURL: URL
    private let maximumBytes: Int
    private let fileManager: FileManager

    init(fileURL: URL, maximumBytes: Int, fileManager: FileManager) {
        self.fileURL = fileURL
        self.maximumBytes = maximumBytes
        self.fileManager = fileManager
    }

    func prepare() throws {
        try ensureFile()
    }

    func append(_ data: Data) throws {
        let currentBytes = ((try? fileManager.attributesOfItem(atPath: fileURL.path)[.size]) as? NSNumber)?.intValue ?? 0
        if currentBytes > 0, currentBytes + data.count > maximumBytes {
            try rotate()
        }
        try ensureFile()
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private func rotate() throws {
        let rotated = URL(fileURLWithPath: fileURL.path + ".1")
        if fileManager.fileExists(atPath: rotated.path) {
            try fileManager.removeItem(at: rotated)
        }
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.moveItem(at: fileURL, to: rotated)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: rotated.path
            )
        }
    }

    private func ensureFile() throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if !fileManager.fileExists(atPath: fileURL.path) {
            guard fileManager.createFile(
                atPath: fileURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

}

private struct BridgeAuditEntry: Encodable {
    let ts: String
    let deviceID: String
    let device: String
    let action: String
    let targetIDs: [String: String]
    let content: BridgeAuditContent

    enum CodingKeys: String, CodingKey {
        case ts, device, action, content
        case deviceID = "device_id"
        case targetIDs = "target_ids"
    }
}

private extension String {
    func prefixString(_ limit: Int) -> String {
        String(prefix(limit))
    }
}
