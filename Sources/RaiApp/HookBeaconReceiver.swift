import Darwin
import Foundation
import RaiCore

enum HookBeaconReceiverError: LocalizedError {
    case activeSocket(String)
    case occupiedPath(String)
    case pathTooLong(String)
    case systemCall(String, Int32)

    var errorDescription: String? {
        switch self {
        case let .activeSocket(path):
            return "Another Rai hook receiver owns this socket: \(path)"
        case let .occupiedPath(path):
            return "Hook socket path contains a non-socket file: \(path)"
        case let .pathTooLong(path):
            return "Hook socket path is too long: \(path)"
        case let .systemCall(name, code):
            return "\(name) failed: \(String(cString: strerror(code)))"
        }
    }
}

final class HookDecisionReply: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32

    init(descriptor: Int32) {
        self.descriptor = descriptor
        var noSigPipe: Int32 = 1
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )
    }

    deinit {
        _ = send(decision: "none")
    }

    @discardableResult
    func allow() -> Bool {
        send(decision: "allow")
    }

    @discardableResult
    func deny(message: String = "Denied from Rai Remote") -> Bool {
        send(decision: "deny", message: message)
    }

    @discardableResult
    func none() -> Bool {
        send(decision: "none")
    }

    private func send(decision: String, message: String? = nil) -> Bool {
        lock.lock()
        let fd = descriptor
        descriptor = -1
        lock.unlock()
        guard fd >= 0 else { return false }
        defer {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }

        var object = ["decision": decision]
        if let message { object["message"] = message }
        guard var data = try? JSONSerialization.data(withJSONObject: object) else {
            return false
        }
        data.append(0x0A)
        return data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.send(
                    fd,
                    bytes.baseAddress! + sent,
                    bytes.count - sent,
                    MSG_NOSIGNAL
                )
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }
    }
}

/// A local, owner-only, newline-delimited JSON receiver for Claude Code hooks.
final class HookBeaconReceiver: @unchecked Sendable {
    private struct SocketIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    static var defaultSocketURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rai", isDirectory: true)
            .appendingPathComponent("hooks.sock")
    }

    private static let maximumLineBytes = 256 * 1_024

    private let socketURL: URL
    private let onBeacon: @Sendable (AgentBeacon, HookDecisionReply?) -> Void
    private let queue = DispatchQueue(label: "gr.krig.rai.hook-beacons")
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var boundIdentity: SocketIdentity?

    init(
        socketURL: URL = HookBeaconReceiver.defaultSocketURL,
        onBeacon: @escaping @Sendable (AgentBeacon) -> Void
    ) {
        self.socketURL = socketURL
        self.onBeacon = { beacon, _ in onBeacon(beacon) }
    }

    init(
        socketURL: URL = HookBeaconReceiver.defaultSocketURL,
        onBeaconWithReply: @escaping @Sendable (AgentBeacon, HookDecisionReply?) -> Void
    ) {
        self.socketURL = socketURL
        self.onBeacon = onBeaconWithReply
    }

    deinit {
        stop()
    }

    func start() throws {
        let directory = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try removeStaleSocket()

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw failure("socket") }
        var createdIdentity: SocketIdentity?
        do {
            var noSigPipe: Int32 = 1
            guard setsockopt(
                fd,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSigPipe,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0 else { throw failure("setsockopt") }

            var address = try socketAddress()
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0 else { throw failure("bind") }
            createdIdentity = socketIdentity(at: socketURL)
            guard Darwin.chmod(socketURL.path, 0o600) == 0 else {
                throw failure("chmod")
            }
            guard Darwin.listen(fd, 8) == 0 else { throw failure("listen") }
        } catch {
            Darwin.close(fd)
            if let createdIdentity,
               socketIdentity(at: socketURL) == createdIdentity {
                Darwin.unlink(socketURL.path)
            }
            throw error
        }

        lock.lock()
        descriptor = fd
        boundIdentity = createdIdentity
        lock.unlock()
        queue.async { [weak self] in self?.acceptLoop(descriptor: fd) }
    }

    func stop() {
        lock.lock()
        let fd = descriptor
        let identity = boundIdentity
        descriptor = -1
        boundIdentity = nil
        lock.unlock()
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        if let identity, socketIdentity(at: socketURL) == identity {
            Darwin.unlink(socketURL.path)
        }
    }

    private func acceptLoop(descriptor: Int32) {
        while currentDescriptor == descriptor {
            let client = Darwin.accept(descriptor, nil, nil)
            guard client >= 0 else {
                if errno == EINTR { continue }
                return
            }
            if !receiveOneLine(from: client) {
                Darwin.close(client)
            }
        }
    }

    /// Returns true when a decision reply owns the client descriptor.
    private func receiveOneLine(from descriptor: Int32) -> Bool {
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while data.count <= Self.maximumLineBytes {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count > 0 else { return false }
            if let newline = buffer[..<count].firstIndex(of: 0x0A) {
                data.append(contentsOf: buffer[..<newline])
                guard data.count <= Self.maximumLineBytes,
                      let beacon = try? JSONDecoder().decode(AgentBeacon.self, from: data)
                else { return false }
                if beacon.event == "PermissionRequest",
                   beacon.awaitsDecision,
                   let requestID = beacon.requestID,
                   UUID(uuidString: requestID) != nil {
                    onBeacon(beacon, HookDecisionReply(descriptor: descriptor))
                    return true
                }
                onBeacon(beacon, nil)
                return false
            }
            data.append(contentsOf: buffer[..<count])
        }
        return false
    }

    private var currentDescriptor: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return descriptor
    }

    private func removeStaleSocket() throws {
        guard FileManager.default.fileExists(atPath: socketURL.path) else { return }
        guard isSocket(at: socketURL) else {
            throw HookBeaconReceiverError.occupiedPath(socketURL.path)
        }
        if hasListener() {
            throw HookBeaconReceiverError.activeSocket(socketURL.path)
        }
        guard Darwin.unlink(socketURL.path) == 0 else { throw failure("unlink") }
    }

    private func hasListener() -> Bool {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }
        defer { Darwin.close(fd) }
        guard var address = try? socketAddress() else { return true }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }

    private func socketAddress() throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketURL.path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            throw HookBeaconReceiverError.pathTooLong(socketURL.path)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            bytes.copyBytes(from: pathBytes)
        }
        return address
    }

    private func socketIdentity(at url: URL) -> SocketIdentity? {
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFSOCK else { return nil }
        return SocketIdentity(device: status.st_dev, inode: status.st_ino)
    }

    private func isSocket(at url: URL) -> Bool {
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0 else { return false }
        return status.st_mode & S_IFMT == S_IFSOCK
    }

    private func failure(_ name: String) -> HookBeaconReceiverError {
        .systemCall(name, errno)
    }
}
