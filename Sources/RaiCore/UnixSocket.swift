import Darwin
import Foundation

enum UnixSocketError: LocalizedError {
    case pathTooLong(String)
    case systemCall(String, Int32)
    case closed

    var errorDescription: String? {
        switch self {
        case .pathTooLong(let path):
            return "Unix socket path is too long: \(path)"
        case .systemCall(let call, let code):
            return "\(call) failed: \(String(cString: strerror(code)))"
        case .closed:
            return "Herdr closed the socket"
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
        lock.lock()
        let fd = descriptor
        lock.unlock()
        guard fd >= 0 else { throw UnixSocketError.closed }

        var payload = data
        payload.append(0x0A)
        try payload.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var sent = 0
            while sent < rawBuffer.count {
                let count = Darwin.write(fd, base.advanced(by: sent), rawBuffer.count - sent)
                guard count > 0 else {
                    throw UnixSocketError.systemCall("write", errno)
                }
                sent += count
            }
        }
    }

    func readLine() throws -> Data {
        while true {
            if let newline = readBuffer.firstIndex(of: 0x0A) {
                let line = readBuffer.prefix(upTo: newline)
                readBuffer.removeSubrange(...newline)
                return Data(line)
            }

            var bytes = [UInt8](repeating: 0, count: 16_384)
            lock.lock()
            let fd = descriptor
            lock.unlock()
            guard fd >= 0 else { throw UnixSocketError.closed }
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
