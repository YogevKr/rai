import Foundation

enum TailscaleServeState: Equatable, Sendable {
    case stopped
    case checking
    case active(host: String)
    case unavailable
    case failed(message: String)
}

actor TailscaleServeController {
    enum StartResult {
        case active(host: String)
        case unavailable
        case failed(message: String)
    }

    private var executableURL: URL?
    private var ownsServe = false
    private let ownershipKey = "companionBridgeOwnsTailscaleServe8443"
    private(set) var state: TailscaleServeState = .stopped

    func start(bridgePort: UInt16, httpsPort: UInt16) async -> StartResult {
        state = .checking
        guard let executableURL = Self.findExecutable() else {
            state = .unavailable
            return .unavailable
        }
        self.executableURL = executableURL

        let status = await Self.run(executableURL, arguments: ["status", "--json"])
        guard status.exitCode == 0,
              let data = status.standardOutput.data(using: .utf8),
              let node = try? JSONDecoder().decode(Status.self, from: data),
              node.selfNode.online,
              !node.selfNode.dnsName.isEmpty else {
            state = .unavailable
            return .unavailable
        }

        var host = node.selfNode.dnsName
        while host.hasSuffix(".") {
            host.removeLast()
        }
        guard !host.isEmpty else {
            state = .unavailable
            return .unavailable
        }

        let serveStatus = await Self.run(
            executableURL,
            arguments: ["serve", "status", "--json"]
        )
        guard serveStatus.exitCode == 0,
              let portState = Self.servePortState(
                  serveStatus.standardOutput,
                  httpsPort: httpsPort,
                  bridgePort: bridgePort
              ) else {
            state = .unavailable
            return .unavailable
        }
        switch portState {
        case .matching:
            ownsServe = UserDefaults.standard.bool(forKey: ownershipKey)
            state = .active(host: host)
            return .active(host: host)
        case .conflict:
            let message = "Tailscale Serve port \(httpsPort) is already in use."
            state = .failed(message: message)
            return .failed(message: message)
        case .free:
            break
        }

        let serve = await Self.run(
            executableURL,
            arguments: ["serve", "--bg", "--https=\(httpsPort)", String(bridgePort)]
        )
        guard serve.exitCode == 0 else {
            let detail = serve.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = detail.isEmpty ? "" : " \(detail)"
            let message = "Tailscale Serve could not start.\(suffix)"
            state = .failed(message: message)
            return .failed(message: message)
        }
        ownsServe = true
        UserDefaults.standard.set(true, forKey: ownershipKey)
        state = .active(host: host)
        return .active(host: host)
    }

    func stop(httpsPort: UInt16) async {
        guard ownsServe, let executableURL else {
            state = .stopped
            return
        }
        let result = await Self.run(
            executableURL,
            arguments: ["serve", "--https=\(httpsPort)", "off"]
        )
        guard result.exitCode == 0 else {
            state = .failed(message: "Tailscale Serve could not stop.")
            return
        }
        ownsServe = false
        UserDefaults.standard.removeObject(forKey: ownershipKey)
        state = .stopped
    }

    private static func findExecutable() -> URL? {
        let fileManager = FileManager.default
        // A launchd-launched app gets a bare PATH (no Homebrew), and the GUI
        // app's CLI can't run headless — outside a login-shell env it tries to
        // start the GUI, fails, and prints the error to stdout WITH EXIT 0.
        // The standalone CLI talks straight to tailscaled's socket, so search
        // its well-known homes explicitly; the GUI binary is a last resort.
        var directories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        directories += ["/opt/homebrew/bin", "/usr/local/bin",
                        NSHomeDirectory() + "/.local/bin"]
        for directory in directories {
            let candidate = URL(fileURLWithPath: directory)
                .appendingPathComponent("tailscale")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        let appURL = URL(
            fileURLWithPath: "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        )
        return fileManager.isExecutableFile(atPath: appURL.path) ? appURL : nil
    }

    private static func servePortState(
        _ json: String,
        httpsPort: UInt16,
        bridgePort: UInt16
    ) -> ServePortState? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let tcp = root["TCP"] as? [String: Any],
              let rawTCPPort = tcp[String(httpsPort)] else {
            return .free
        }
        guard let tcpPort = rawTCPPort as? [String: Any],
              tcpPort["HTTPS"] as? Bool == true else {
            return .conflict
        }

        let expectedProxy = "http://127.0.0.1:\(bridgePort)"
        let web = root["Web"] as? [String: Any] ?? [:]
        let allowFunnel = root["AllowFunnel"] as? [String: Any] ?? [:]
        for (address, rawServer) in web where address.hasSuffix(":\(httpsPort)") {
            guard allowFunnel[address] as? Bool != true else {
                return .conflict
            }
            guard let server = rawServer as? [String: Any],
                  let handlers = server["Handlers"] as? [String: Any],
                  let rootHandler = handlers["/"] as? [String: Any] else {
                continue
            }
            if rootHandler["Proxy"] as? String == expectedProxy {
                return .matching
            }
        }
        return .conflict
    }

    private static func run(
        _ executableURL: URL,
        arguments: [String]
    ) async -> ProcessResult {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError

        do {
            try process.run()
            async let outputData = Task.detached {
                standardOutput.fileHandleForReading.readDataToEndOfFile()
            }.value
            async let errorData = Task.detached {
                standardError.fileHandleForReading.readDataToEndOfFile()
            }.value
            await Self.waitForExit(process)
            let (capturedOutput, capturedError) = await (outputData, errorData)
            return ProcessResult(
                exitCode: process.terminationStatus,
                standardOutput: String(data: capturedOutput, encoding: .utf8) ?? "",
                standardError: String(data: capturedError, encoding: .utf8) ?? ""
            )
        } catch {
            return ProcessResult(
                exitCode: -1,
                standardOutput: "",
                standardError: error.localizedDescription
            )
        }
    }

    private static func waitForExit(_ process: Process) async {
        await withTaskCancellationHandler {
            await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    process.waitUntilExit()
                    return true
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(10))
                    return false
                }
                if await group.next() == false, process.isRunning {
                    process.terminate()
                }
                group.cancelAll()
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }
}

private enum ServePortState {
    case free
    case matching
    case conflict
}

private struct Status: Decodable {
    let selfNode: SelfNode

    enum CodingKeys: String, CodingKey {
        case selfNode = "Self"
    }

    struct SelfNode: Decodable {
        let dnsName: String
        let online: Bool

        enum CodingKeys: String, CodingKey {
            case dnsName = "DNSName"
            case online = "Online"
        }
    }
}

private struct ProcessResult {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}
