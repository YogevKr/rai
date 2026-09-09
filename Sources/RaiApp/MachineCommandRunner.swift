import Darwin
import Foundation
import RaiCore

enum MachineCommandRunner {
    struct Output: Sendable {
        let status: Int32
        let standardOutput: Data
        let standardError: Data
    }

    static func run(_ arguments: [String]) async throws -> Data {
        guard let binary = HerdrCLI.resolvedBinaryPath else {
            throw MachineCatalogError.invalid("Install Herdr before managing machines.")
        }
        let result = try await capture(binary: binary, arguments: arguments)
        guard result.status == 0 else {
            let detail = String(decoding: result.standardError, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw MachineCatalogError.invalid(detail.isEmpty ? "Herdr could not complete the machine operation." : detail)
        }
        return result.standardOutput
    }

    static func capture(binary: String, arguments: [String], timeout: TimeInterval = 120,
                        environment: [String: String]? = nil) async throws -> Output {
        let cancellation = MachineCommandCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached {
                try execute(binary: binary, arguments: arguments, timeout: timeout, environment: environment, cancellation: cancellation)
            }.value
        } onCancel: { cancellation.cancel() }
    }

    private static func execute(binary: String, arguments: [String], timeout: TimeInterval,
                                environment: [String: String]?, cancellation: MachineCommandCancellation) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = environment ?? ProcessInfo.processInfo.environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output; process.standardError = errors
        let captures = [MachineOutputCapture(output.fileHandleForReading), MachineOutputCapture(errors.fileHandleForReading)]
        defer { captures.forEach { try? $0.handle.close() } }
        try cancellation.launch(process)
        let pid = process.processIdentifier
        let ownsGroup = getpgid(pid) == pid || Darwin.kill(-pid, 0) == 0
        let terminationTarget = ownsGroup ? -pid : pid
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            if cancellation.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline {
                terminate(process, target: terminationTarget)
                if cancellation.isCancelled { throw CancellationError() }
                throw MachineCatalogError.invalid("The machine command timed out.")
            }
            var descriptors = captures.map { pollfd(fd: $0.eof ? -1 : $0.handle.fileDescriptor, events: Int16(POLLIN), revents: 0) }
            _ = poll(&descriptors, nfds_t(descriptors.count), 50)
            for capture in captures { capture.drain() }
            if captures.contains(where: \.overflow) {
                terminate(process, target: terminationTarget)
                throw MachineCatalogError.invalid("The machine response is too large.")
            }
            if !process.isRunning {
                for capture in captures { capture.drain() }
                guard !captures.contains(where: \.overflow) else {
                    throw MachineCatalogError.invalid("The machine response is too large.")
                }
                return Output(status: process.terminationStatus, standardOutput: captures[0].data, standardError: captures[1].data)
            }
        }
    }

    private static func terminate(_ process: Process, target: Int32) {
        let ownsGroup = target < 0
        guard ownsGroup || process.isRunning else { return }
        Darwin.kill(target, SIGTERM)
        usleep(200_000)
        if ownsGroup || process.isRunning { Darwin.kill(target, SIGKILL) }
    }
}

private final class MachineCommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }

    func launch(_ process: Process) throws {
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            try process.run()
        }
    }
}

/// Nonblocking reads drain both pipes without waiting for inherited descriptors to close.
private final class MachineOutputCapture {
    let handle: FileHandle
    private(set) var data = Data()
    private(set) var overflow = false
    private(set) var eof = false
    init(_ handle: FileHandle) {
        self.handle = handle
        let flags = fcntl(handle.fileDescriptor, F_GETFL)
        _ = fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK)
    }

    func drain() {
        var buffer = [UInt8](repeating: 0, count: 8192)
        for _ in 0..<16 {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
            if count == 0 { eof = true }
            guard count > 0 else { return }
            let available = max(0, 131_072 - data.count)
            if count > available { overflow = true }
            data.append(contentsOf: buffer.prefix(min(count, available)))
        }
    }
}
