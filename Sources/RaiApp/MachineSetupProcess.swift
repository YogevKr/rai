import Darwin
import Foundation
import RaiCore

/// A foreground setup process gets a terminal. Background reconnect never calls this type.
@MainActor
final class MachineSetupProcess {
    private let process = Process()
    private var terminal: FileHandle?
    private var ownedProcessGroup: Int32?
    private var timer: Task<Void, Never>?
    private var output = Data()
    private(set) var outputTruncated = false
    private var prompt: UUID?
    private var completed = false
    private let update: (String, UUID?) -> Void
    private let finish: (Int32) -> Void

    init(update: @escaping (String, UUID?) -> Void, finish: @escaping (Int32) -> Void) {
        self.update = update; self.finish = finish
    }

    func start(binary: String, arguments: [String], environment: [String: String]? = nil) throws {
        var master: Int32 = -1, slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw MachineCatalogError.invalid("The setup terminal could not start.")
        }
        let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        terminal = masterHandle
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = environment ?? ProcessInfo.processInfo.environment
        process.standardInput = slaveHandle; process.standardOutput = slaveHandle; process.standardError = slaveHandle
        do {
            try process.run()
            let pid = process.processIdentifier
            if getpgid(pid) == pid || Darwin.kill(-pid, 0) == 0 { ownedProcessGroup = pid }
            try slaveHandle.close()
        } catch {
            terminal = nil
            throw error
        }
        let process = process
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(masterHandle.fileDescriptor, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                let bytes = Data(buffer.prefix(count))
                let delivered = DispatchSemaphore(value: 0)
                Task { @MainActor in self?.receive(bytes); delivered.signal() }
                delivered.wait()
            }
            process.waitUntilExit()
            Task { @MainActor in self?.complete(process.terminationStatus) }
        }
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled else { return }
            self?.cancel()
        }
    }

    func answer(promptID: UUID, approve: Bool) throws {
        guard !completed, !outputTruncated, process.isRunning, prompt == promptID, let terminal else { throw HerdrEndpointError.staleIdentity }
        prompt = nil
        update(String(decoding: output, as: UTF8.self), nil)
        try terminal.write(contentsOf: Data((approve ? "yes\n" : "no\n").utf8))
    }

    func cancel() {
        guard !completed else { return }
        prompt = nil
        let pid = process.processIdentifier
        let ownsGroup = ownedProcessGroup != nil
        let target = ownedProcessGroup.map { -$0 } ?? pid
        if ownsGroup || process.isRunning { Darwin.kill(target, SIGTERM) }
        let process = process
        Task {
            try? await Task.sleep(for: .seconds(2))
            // A child can retain the terminal after its parent exits.
            if ownsGroup || process.isRunning { Darwin.kill(target, SIGKILL) }
        }
        complete(-1)
    }

    private func receive(_ bytes: Data) {
        guard !completed else { return }
        output.append(bytes)
        if output.count > 65_536 { outputTruncated = true; output.removeFirst(output.count - 65_536) }
        let text = (outputTruncated ? "Output exceeded the review limit. Cancel setup and inspect the target before trying again.\n" : "")
            + String(decoding: output, as: UTF8.self)
        let suffix = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !outputTruncated, suffix.hasSuffix("[y/n]") { if prompt == nil { prompt = UUID() } }
        else { prompt = nil }
        update(text, prompt)
    }

    private func complete(_ status: Int32) {
        guard !completed else { return }
        completed = true
        timer?.cancel(); timer = nil
        terminal = nil
        finish(status)
    }
}
