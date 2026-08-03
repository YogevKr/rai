import RaiCore
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
    let id = UUID()
    let target: String
    let sessionName: String
    let remoteSocketPath: String
    let localSocketPath: String
    let remoteClientSocketPath: String
    let localClientSocketPath: String

    var onUnexpectedExit: ((UUID, String) -> Void)?

    private let process = Process()
    private let errorPipe = Pipe()
    private var intentionalStop = false
    private var ready = false
    private var exitStatus: Int32?
    private var exitDetail: String?

    init(target: String, sessionName: String, remoteSocketPath: String) {
        self.target = target
        self.sessionName = sessionName
        self.remoteSocketPath = remoteSocketPath
        localSocketPath = "/tmp/rai-\(UUID().uuidString.prefix(12)).sock"
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

    var tunnelArguments: [String] {
        [
            "-N",
            "-o", "StreamLocalBindUnlink=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-L", "\(localSocketPath):\(remoteSocketPath)",
            "-L", "\(localClientSocketPath):\(remoteClientSocketPath)",
            target,
        ]
    }

    func start() async throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = tunnelArguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        process.terminationHandler = { [weak self, errorPipe] process in
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            Task { @MainActor [weak self] in
                self?.processDidExit(
                    status: process.terminationStatus,
                    detail: detail
                )
            }
        }

        do {
            try process.run()
        } catch {
            throw RemoteConnectionError.tunnelFailed(error.localizedDescription)
        }

        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: localSocketPath),
               FileManager.default.fileExists(atPath: localClientSocketPath) {
                ready = true
                return
            }
            guard process.isRunning else {
                try? await Task.sleep(for: .milliseconds(50))
                throw RemoteConnectionError.tunnelFailed(
                    exitDetail?.isEmpty == false
                        ? exitDetail!
                        : "ssh exited with status \(exitStatus ?? process.terminationStatus)."
                )
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        stop()
        throw RemoteConnectionError.tunnelTimedOut
    }

    func stop() {
        intentionalStop = true
        if process.isRunning {
            process.terminate()
            let runningProcess = process
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                if runningProcess.isRunning {
                    Darwin.kill(runningProcess.processIdentifier, SIGKILL)
                }
            }
        }
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

    private func processDidExit(status: Int32, detail: String?) {
        exitStatus = status
        exitDetail = detail
        try? FileManager.default.removeItem(atPath: localSocketPath)
        try? FileManager.default.removeItem(atPath: localClientSocketPath)
        guard ready, !intentionalStop else { return }
        let message = detail?.isEmpty == false
            ? detail!
            : "ssh exited with status \(status)."
        onUnexpectedExit?(id, message)
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
        await withCheckedContinuation { continuation in
            let process = Process()
            let standardOutput = Pipe()
            let standardError = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = [
                "-o", "ConnectTimeout=10",
                target,
            ] + remoteArguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = standardOutput
            process.standardError = standardError
            do {
                try process.run()
            } catch {
                continuation.resume(
                    returning: SSHResult(
                        succeeded: false,
                        standardOutput: "",
                        standardError: error.localizedDescription
                    )
                )
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
                let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(
                    returning: SSHResult(
                        succeeded: process.terminationStatus == 0,
                        standardOutput: String(data: outputData, encoding: .utf8) ?? "",
                        standardError: String(data: errorData, encoding: .utf8) ?? ""
                    )
                )
            }
        }
    }
}
