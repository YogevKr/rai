import RaiCore
import CryptoKit
import Darwin
import Foundation

enum RemoteConnectionError: LocalizedError {
    case invalidTarget
    case sessionNotFound(String)
    case sessionNotRunning(String)
    case discoveryFailed(String)
    case tunnelFailed(String)
    case tunnelTimedOut

    var errorDescription: String? {
        switch self {
        case .invalidTarget:
            return "Enter an SSH target such as user@host."
        case .sessionNotFound(let name):
            return "The remote Herdr session “\(name)” was not found."
        case .sessionNotRunning(let name):
            return "The remote Herdr session “\(name)” is not running."
        case .discoveryFailed(let message):
            return "Couldn’t list remote Herdr sessions: \(message)"
        case .tunnelFailed(let message):
            return "The SSH tunnel failed: \(message)"
        case .tunnelTimedOut:
            return "The SSH tunnel did not become ready in time."
        }
    }
}

@MainActor
final class RemoteConnection {
    struct Context: Equatable, Sendable {
        let target: String
        let sessionName: String
        let remoteSocketPath: String
    }

    var context: Context { .init(target: target, sessionName: sessionName, remoteSocketPath: remoteSocketPath) }
    var isRunning: Bool { ready && !intentionalStop && !registeredForwardSpecs.isEmpty }

    var hasLocalSockets: Bool {
        FileManager.default.fileExists(atPath: localSocketPath)
            && FileManager.default.fileExists(atPath: localClientSocketPath)
    }

    let id = UUID()
    let target: String
    let sessionName: String
    let remoteSocketPath: String
    let localSocketPath: String
    let remoteClientSocketPath: String
    let localClientSocketPath: String

    var onUnexpectedExit: ((UUID, String) -> Void)?

    private var intentionalStop = false
    private var ready = false
    private var registeredForwardSpecs: [String] = []
    private var healthTask: Task<Void, Never>?

    init(target: String, sessionName: String, remoteSocketPath: String) {
        self.target = target
        self.sessionName = sessionName
        self.remoteSocketPath = remoteSocketPath
        let root = AppDataPaths.current.isolatedRoot?.path ?? "/tmp"
        localSocketPath = root + "/rai-\(UUID().uuidString.prefix(12)).sock"
        remoteClientSocketPath = Self.clientSocketPath(for: remoteSocketPath)
        localClientSocketPath = Self.clientSocketPath(for: localSocketPath)
    }

    /// herdr serves RPC on `herdr.sock` and the terminal-attach data plane on a
    /// sibling `herdr-client.sock`; its CLI derives that sibling name from
    /// `HERDR_SOCKET_PATH`. Both sockets must be forwarded, and the local pair
    /// must use the same derivation so spawned `herdr terminal attach`
    /// processes find the client socket without any extra environment.
    static func clientSocketPath(for socketPath: String) -> String {
        guard socketPath.hasSuffix(".sock") else {
            return socketPath + "-client"
        }
        return String(socketPath.dropLast(".sock".count)) + "-client.sock"
    }

    deinit { healthTask?.cancel() }

    /// Builds an OpenSSH control command for one stream-local forward.
    /// The master owns the listener, so no second SSH handshake is needed.
    func forwardArguments(
        operation: String = "forward",
        localPath: String,
        remotePath: String
    ) throws -> [String] {
        try Self.sshConfigurationArguments(target: target) + [
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "StreamLocalBindUnlink=yes",
            "-O", operation,
            "-L", "\(localPath):\(remotePath)",
            target,
        ]
    }

    func start() async throws {
        var started = false
        defer { if !started { stop() } }
        if let fixture = try LabSSHConfiguration.load(root: AppDataPaths.current.isolatedRoot) {
            try fixture.validate(target: target, socketPath: remoteSocketPath)
        }
        try await Self.ensureControlMaster(target: target)
        try await registerForwards([
            (localPath: localSocketPath, remotePath: remoteSocketPath),
            (localPath: localClientSocketPath, remotePath: remoteClientSocketPath),
        ])

        for _ in 0..<100 {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: localSocketPath),
               FileManager.default.fileExists(atPath: localClientSocketPath) {
                ready = true
                started = true
                startHealthMonitor()
                return
            }
            // OpenSSH creates stream-local listeners before the control command
            // returns. Keep a short guard for slow filesystems.
            try await Task.sleep(for: .milliseconds(20))
        }

        stop()
        throw RemoteConnectionError.tunnelTimedOut
    }

    private func registerForwards(
        _ forwards: [(localPath: String, remotePath: String)]
    ) async throws {
        var arguments = try Self.sshConfigurationArguments(target: target) + [
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "StreamLocalBindUnlink=yes",
            "-O", "forward",
        ]
        for forward in forwards {
            arguments += ["-L", "\(forward.localPath):\(forward.remotePath)"]
        }
        arguments.append(target)
        let result: MachineCommandRunner.Output
        do {
            result = try await MachineCommandRunner.capture(
                binary: "/usr/bin/ssh", arguments: arguments, timeout: 10
            )
        } catch {
            await Self.cancelForwardSpecs(
                target: target,
                specs: forwards.map { "\($0.localPath):\($0.remotePath)" }
            )
            throw RemoteConnectionError.tunnelFailed(error.localizedDescription)
        }
        guard result.status == 0 else {
            let detail = String(decoding: result.standardError, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            await Self.cancelForwardSpecs(
                target: target,
                specs: forwards.map { "\($0.localPath):\($0.remotePath)" }
            )
            throw RemoteConnectionError.tunnelFailed(
                detail.isEmpty ? "Could not create the SSH stream forward." : detail
            )
        }
        registeredForwardSpecs.append(contentsOf: forwards.map {
            "\($0.localPath):\($0.remotePath)"
        })
    }

    private func startHealthMonitor() {
        healthTask?.cancel()
        healthTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self, !self.intentionalStop else { return }
                guard self.hasLocalSockets else {
                    self.controlMasterDidExit(message: "The SSH tunnel sockets disappeared.")
                    return
                }
                guard await Self.controlMasterIsAlive(target: self.target) else {
                    self.controlMasterDidExit()
                    return
                }
            }
        }
    }

    private static func controlMasterIsAlive(target: String) async -> Bool {
        guard let configuration = try? sshConfigurationArguments(target: target),
              let result = try? await MachineCommandRunner.capture(
                  binary: "/usr/bin/ssh",
                  arguments: configuration + [
                      "-o", "BatchMode=yes",
                      "-o", "StrictHostKeyChecking=yes",
                      "-O", "check",
                      target,
                  ],
                  timeout: 5
              ) else { return false }
        return result.status == 0
    }

    private func controlMasterDidExit(message: String = "The SSH control connection exited.") {
        guard ready, !intentionalStop else { return }
        ready = false
        stop()
        onUnexpectedExit?(id, message)
    }

    /// Keep one private SSH master per target. Discovery normally creates it,
    /// but a saved remote view can start after that master expires.
    private static func ensureControlMaster(target: String) async throws {
        let configuration = try sshConfigurationArguments(target: target)
        let check = try await MachineCommandRunner.capture(
            binary: "/usr/bin/ssh",
            arguments: configuration + [
                "-o", "BatchMode=yes",
                "-o", "StrictHostKeyChecking=yes",
                "-O", "check",
                target,
            ],
            timeout: 5
        )
        if check.status == 0 { return }

        let master = try await MachineCommandRunner.capture(
            binary: "/usr/bin/ssh",
            arguments: configuration + [
                "-o", "ControlMaster=yes",
                "-o", "ControlPersist=600",
                "-o", "BatchMode=yes",
                "-o", "StrictHostKeyChecking=yes",
                "-o", "ConnectTimeout=10",
                "-fN",
                target,
            ],
            timeout: 20
        )
        if master.status == 0 { return }

        // Another view may have won the race to create the master.
        let retry = try await MachineCommandRunner.capture(
            binary: "/usr/bin/ssh",
            arguments: configuration + [
                "-o", "BatchMode=yes",
                "-o", "StrictHostKeyChecking=yes",
                "-O", "check",
                target,
            ],
            timeout: 5
        )
        guard retry.status == 0 else {
            let detail = String(decoding: master.standardError, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw RemoteConnectionError.tunnelFailed(
                detail.isEmpty ? "Could not create the SSH control connection." : detail
            )
        }
    }

    func stop() {
        intentionalStop = true
        healthTask?.cancel()
        healthTask = nil
        ready = false
        let forwards = registeredForwardSpecs
        registeredForwardSpecs.removeAll()
        removeLocalSockets()
        guard !forwards.isEmpty else { return }
        Task { [target] in
            await Self.cancelForwardSpecs(target: target, specs: forwards)
        }
    }

    private static func cancelForwardSpecs(target: String, specs: [String]) async {
        for spec in specs {
            guard let arguments = try? sshConfigurationArguments(target: target) + [
                "-o", "BatchMode=yes",
                "-o", "StrictHostKeyChecking=yes",
                "-O", "cancel",
                "-L", spec,
                target,
            ] else { continue }
            _ = try? await MachineCommandRunner.capture(
                binary: "/usr/bin/ssh", arguments: arguments, timeout: 5
            )
        }
    }

    private func removeLocalSockets() {
        try? FileManager.default.removeItem(atPath: localSocketPath)
        try? FileManager.default.removeItem(atPath: localClientSocketPath)
    }

    static func discoverSocket(
        target rawTarget: String,
        sessionName rawSessionName: String
    ) async throws -> (target: String, sessionName: String, socketPath: String) {
        let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValid(target: target) else {
            throw RemoteConnectionError.invalidTarget
        }
        _ = try sshConfigurationArguments(target: target)
        let trimmedName = rawSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionName = trimmedName.isEmpty ? "default" : trimmedName
        let result = await runSSH(
            target: target,
            remoteArguments: ["herdr", "session", "list", "--json"]
        )

        if result.succeeded,
           let sessions = try? SessionListParser.parse(result.standardOutput) {
            guard let session = sessions.first(where: { $0.name == sessionName }) else {
                if sessionName == "default" {
                    return try await defaultSocket(target: target)
                }
                throw RemoteConnectionError.sessionNotFound(sessionName)
            }
            guard session.isRunning else {
                throw RemoteConnectionError.sessionNotRunning(sessionName)
            }
            return (target, sessionName, session.socketPath)
        }

        if sessionName == "default" {
            return try await defaultSocket(
                target: target,
                discoveryError: result.errorOutput
            )
        }
        let detail = result.errorOutput.isEmpty
            ? "Herdr returned an unreadable session list."
            : result.errorOutput
        throw RemoteConnectionError.discoveryFailed(detail)
    }

    /// Lists the herdr sessions on a remote target, for the session menu.
    static func listSessions(target: String) async throws -> [HerdrSession] {
        _ = try sshConfigurationArguments(target: target)
        let result = await runSSH(
            target: target,
            remoteArguments: ["herdr", "session", "list", "--json"]
        )
        guard result.succeeded else {
            throw RemoteConnectionError.discoveryFailed(result.errorOutput)
        }
        return try SessionListParser.parse(result.standardOutput)
    }

    private static func defaultSocket(
        target: String,
        discoveryError: String = ""
    ) async throws -> (target: String, sessionName: String, socketPath: String) {
        // OpenSSH does not expand `~` in a stream-local forwarding destination.
        // A command-only SSH connection starts in the remote user's home, so
        // `pwd` resolves the documented ~/.config/herdr fallback safely.
        let homeResult = await runSSH(target: target, remoteArguments: ["pwd"])
        let home = homeResult.standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard homeResult.succeeded, home.hasPrefix("/") else {
            let detail = discoveryError.isEmpty
                ? homeResult.errorOutput
                : discoveryError
            throw RemoteConnectionError.discoveryFailed(
                detail.isEmpty ? "Couldn’t resolve the remote home directory." : detail
            )
        }
        return (
            target,
            "default",
            URL(fileURLWithPath: home)
                .appendingPathComponent(".config/herdr/herdr.sock").path
        )
    }

    private static func isValid(target: String) -> Bool {
        !target.isEmpty
            && !target.hasPrefix("-")
            && target.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }

    private struct SSHResult {
        let succeeded: Bool
        let standardOutput: String
        let standardError: String

        var errorOutput: String {
            let error = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            return error.isEmpty
                ? standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                : error
        }
    }

    private static func runSSH(
        target: String,
        remoteArguments: [String]
    ) async -> SSHResult {
        let configuration: [String]
        do { configuration = try sshConfigurationArguments(target: target) }
        catch { return SSHResult(succeeded: false, standardOutput: "", standardError: error.localizedDescription) }
        do {
            // Discovery often runs before the socket tunnel starts. Create the
            // shared master here so discovery and the later tunnel reuse one
            // handshake instead of opening two connections in sequence.
            try await ensureControlMaster(target: target)
        } catch {
            return SSHResult(
                succeeded: false,
                standardOutput: "",
                standardError: error.localizedDescription
            )
        }
        do {
            let result = try await MachineCommandRunner.capture(binary: "/usr/bin/ssh", arguments: configuration + [
                "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10", target,
            ] + remoteArguments, timeout: 20)
            return SSHResult(succeeded: result.status == 0,
                             standardOutput: String(decoding: result.standardOutput, as: UTF8.self),
                             standardError: String(decoding: result.standardError, as: UTF8.self))
        } catch {
            return SSHResult(succeeded: false, standardOutput: "", standardError: error.localizedDescription)
        }
    }

    /// Runs a non-interactive command through the target's shared SSH master.
    /// Remote helpers must use this path so a palette action does not open a
    /// second handshake while the endpoint tunnel is already active.
    static func remoteCommandOutput(
        target: String,
        arguments: [String]
    ) async -> String? {
        let result = await runSSH(target: target, remoteArguments: arguments)
        guard result.succeeded else { return nil }
        return result.standardOutput
    }

    static func foregroundArguments(target: String, sessionName: String, arguments: [String]) throws -> [String] {
        let session = sessionName == "default" ? [] : ["--session", sessionName]
        let command = (["herdr"] + session + arguments).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        return try sshConfigurationArguments(target: target)
            + ["-tt", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10",
               "-o", "ObscureKeystrokeTiming=no", target, command]
    }

    static func foregroundAttachArguments(
        target: String,
        sessionName: String,
        terminalID: String
    ) throws -> [String] {
        try foregroundArguments(
            target: target,
            sessionName: sessionName,
            // A remote Rai view must never displace a Herdr client that owns
            // the terminal, because takeover resets that client's Codex UI.
            arguments: ["terminal", "attach", terminalID]
        )
    }

    static func sshConfigurationArguments(target: String) throws -> [String] {
        var arguments: [String] = []
        if let fixture = try LabSSHConfiguration.load(root: AppDataPaths.current.isolatedRoot) {
            try fixture.validate(target: target)
            arguments += ["-F", fixture.configPath]
        }

        // Herdr's remote client uses the same settings. Compression helps
        // screen updates on narrow links. Disable timing obfuscation because
        // the app already handles remote typing prediction. A private control
        // socket lets all commands share one handshake without adopting a
        // user's unrelated ControlMaster.
        arguments += ["-C", "-S", try sshControlPath(target: target),
                      "-o", "ControlMaster=auto",
                      "-o", "ControlPersist=600",
                      "-o", "IgnoreUnknown=ObscureKeystrokeTiming",
                      "-o", "ObscureKeystrokeTiming=no",
                      "-o", "ServerAliveInterval=15",
                      "-o", "ServerAliveCountMax=3"]
        return arguments
    }

    private static func sshControlPath(target: String) throws -> String {
        let namespace = AppDataPaths.current.isolatedRoot?.path
            ?? AppDataPaths.current.applicationSupport.path
        let digest = SHA256.hash(data: Data((namespace + "\0" + target).utf8))
        let suffix = digest.prefix(24).map { String(format: "%02x", $0) }.joined()
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("rai-hssh-\(getuid())", isDirectory: true)
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            do {
                try manager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch CocoaError.fileWriteFileExists {
                // Another Rai process created the shared directory first.
            }
        }
        let attributes = try manager.attributesOfItem(atPath: directory.path)
        guard (attributes[.type] as? FileAttributeType) == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o700 else {
            throw RemoteConnectionError.tunnelFailed(
                "The SSH control directory is not private to this user."
            )
        }
        return directory.appendingPathComponent("control-\(suffix)").path
    }
}
