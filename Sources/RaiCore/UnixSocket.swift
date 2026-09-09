import Darwin
import Foundation

enum UnixSocketError: LocalizedError {
    case pathTooLong(String)
    case systemCall(String, Int32)
    case closed
    case lineTooLong(Int)

    var errorDescription: String? {
        switch self {
        case .pathTooLong(let path):
            return "Unix socket path is too long: \(path)"
        case .systemCall(let call, let code):
            return "\(call) failed: \(String(cString: strerror(code)))"
        case .closed:
            return "Herdr closed the socket"
        case .lineTooLong(let limit):
            return "Herdr returned a response above the \(limit)-byte limit"
        }
    }
}

final class UnixSocket: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var readBuffer = Data()

    init(path: String) throws {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw UnixSocketError.systemCall("socket", errno)
        }

        var noSigPipe: Int32 = 1
        guard setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw UnixSocketError.systemCall("setsockopt", code)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            Darwin.close(fd)
            throw UnixSocketError.pathTooLong(path)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            bytes.copyBytes(from: pathBytes)
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw UnixSocketError.systemCall("connect", code)
        }
        descriptor = fd
    }

    deinit {
        close()
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { return }
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
        descriptor = -1
    }

    func writeLine(_ data: Data) throws {
        var payload = data
        payload.append(0x0A)
        try write(payload)
    }

    func writeFrame(_ data: Data) throws {
        guard data.count <= HerdrEndpointWire.maximumFrameBytes else {
            throw HerdrEndpointError.limitExceeded
        }
        var length = UInt32(data.count).littleEndian
        var payload = withUnsafeBytes(of: &length) { Data($0) }
        payload.append(data)
        try write(payload)
    }

    private func duplicateDescriptor() throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { throw UnixSocketError.closed }
        let fd = Darwin.dup(descriptor)
        guard fd >= 0 else { throw UnixSocketError.systemCall("dup", errno) }
        return fd
    }

    private func write(_ payload: Data) throws {
        let fd = try duplicateDescriptor()
        defer { Darwin.close(fd) }
        guard fd >= 0 else { throw UnixSocketError.closed }
        try payload.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var sent = 0
            while sent < rawBuffer.count {
                let count = Darwin.write(fd, base.advanced(by: sent), rawBuffer.count - sent)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw UnixSocketError.systemCall("write", errno)
                }
                sent += count
            }
        }
    }

    /// Binary and line framing use separate socket instances. Never mix their readers.
    func readFrame() throws -> Data {
        let fd = try duplicateDescriptor()
        defer { Darwin.close(fd) }
        let prefix = try readExactly(4, descriptor: fd)
        let length = prefix.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        guard length > 0, length <= HerdrEndpointWire.maximumFrameBytes else {
            throw HerdrEndpointError.limitExceeded
        }
        return try readExactly(Int(length), descriptor: fd)
    }

    private func readExactly(_ length: Int, descriptor: Int32) throws -> Data {
        var data = Data(count: length)
        try data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var received = 0
            while received < length {
                let count = Darwin.read(descriptor, base.advanced(by: received), length - received)
                if count < 0, errno == EINTR { continue }
                if count < 0 { throw UnixSocketError.systemCall("read", errno) }
                guard count > 0 else { throw UnixSocketError.closed }
                received += count
            }
        }
        return data
    }

    func readLine(maximumBytes: Int? = nil) throws -> Data {
        let fd = try duplicateDescriptor()
        defer { Darwin.close(fd) }
        while true {
            if let newline = readBuffer.firstIndex(of: 0x0A) {
                let line = readBuffer.prefix(upTo: newline)
                if let maximumBytes, line.count > maximumBytes { throw UnixSocketError.lineTooLong(maximumBytes) }
                readBuffer.removeSubrange(...newline)
                return Data(line)
            }
            var capacity = 16_384
            if let maximumBytes {
                guard readBuffer.count <= maximumBytes else { throw UnixSocketError.lineTooLong(maximumBytes) }
                capacity = min(capacity, maximumBytes - readBuffer.count) + 1
            }
            var bytes = [UInt8](repeating: 0, count: capacity)
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw UnixSocketError.systemCall("read", errno)
            }
            guard count > 0 else { throw UnixSocketError.closed }
            readBuffer.append(bytes, count: count)
        }
    }
}
