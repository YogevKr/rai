import Darwin
import Foundation

public enum UnixSocketError: LocalizedError {
    case pathTooLong(String)
    case systemCall(String, Int32)
    case closed
    case lineTooLong(limit: Int)

    public var errorDescription: String? {
        switch self {
        case .pathTooLong(let path):
            return "Unix socket path is too long: \(path)"
        case .systemCall(let call, let code):
            return "\(call) failed: \(String(cString: strerror(code)))"
        case .closed:
            return "The peer closed the socket"
        case .lineTooLong(let limit):
            return "Peer sent an unterminated line longer than \(limit) bytes"
        }
    }
}

public final class UnixSocket: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var closed = false
    private var readBuffer = Data()
    /// An unterminated line beyond this is garbage, not a message — stop
    /// buffering it instead of growing without bound. Herdr responses carry
    /// whole scrollbacks in one line, so the default is generous.
    private let maxLineBytes: Int

    public init(path: String, maxLineBytes: Int = 256 * 1024 * 1024) throws {
        self.maxLineBytes = maxLineBytes
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

        let address: sockaddr_un
        do {
            address = try Self.makeAddress(path: path)
        } catch {
            Darwin.close(fd)
            throw error
        }
        let result = withUnsafePointer(to: address) { pointer in
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

    /// Adopts an already-connected descriptor (a server's accepted client) and
    /// owns it from here on. SO_NOSIGPIPE is applied so a peer that vanishes
    /// mid-write surfaces as an error, never a signal.
    public init(adoptingDescriptor fd: Int32, maxLineBytes: Int = 256 * 1024 * 1024) {
        self.maxLineBytes = maxLineBytes
        var noSigPipe: Int32 = 1
        setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )
        descriptor = fd
    }

    /// True when `path` exists and is a unix socket (as opposed to absent,
    /// or occupied by an unrelated file). Shared by every "is a peer
    /// actually listening here" check so they cannot disagree.
    public static func isSocketFile(atPath path: String) -> Bool {
        var status = stat()
        guard stat(path, &status) == 0 else { return false }
        return (status.st_mode & S_IFMT) == S_IFSOCK
    }

    /// Builds a `sockaddr_un` for `path`, shared by this connecting init and
    /// `HelperServer`'s binding init — the two are otherwise easy to let
    /// drift apart on this repo's only hand-rolled unsafe-pointer code.
    public static func makeAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            throw UnixSocketError.pathTooLong(path)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            bytes.copyBytes(from: pathBytes)
        }
        return address
    }

    /// Shuts the socket down (any blocked read/write on this fd unblocks
    /// with `.closed`) but does not free the descriptor number — that would
    /// race a syscall in flight on another thread, since the kernel can
    /// recycle the number instantly (a server's accept loop opens new fds
    /// constantly). Every method that touches `descriptor` runs as a call ON
    /// this instance, so the calling thread's stack frame holds a strong
    /// reference for the syscall's duration; ARC therefore cannot deinit
    /// (and free the fd) until that call returns. `deinit` does the real
    /// close(2) once nothing can be mid-syscall.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        if descriptor >= 0 {
            Darwin.shutdown(descriptor, SHUT_RDWR)
        }
    }

    deinit {
        // shutdown() first is redundant given the invariant above (every
        // current caller calls close() before dropping its last reference,
        // so nothing can be mid-syscall here) — kept anyway as a free safety
        // net: if a FUTURE caller ever violates that invariant, this at
        // least unblocks a straggler syscall before the fd number is freed,
        // rather than only the raw close() that invariant violation would
        // otherwise race against.
        if descriptor >= 0 {
            Darwin.shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
        }
    }

    private func activeDescriptor() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        return closed ? nil : (descriptor >= 0 ? descriptor : nil)
    }

    /// Bounds how long a read may block (SO_RCVTIMEO); a timed-out read
    /// surfaces as a thrown EAGAIN. nil restores blocking reads. Used by
    /// probes that must not hang on a peer that accepted the connection but
    /// never answers.
    public func setReceiveTimeout(_ seconds: Double?) {
        setTimeout(option: SO_RCVTIMEO, seconds: seconds)
    }

    /// Bounds how long a write may block (SO_SNDTIMEO); a timed-out write
    /// surfaces as a thrown EAGAIN. nil restores blocking writes. A peer
    /// that stops draining its socket must never park the writer forever.
    public func setSendTimeout(_ seconds: Double?) {
        setTimeout(option: SO_SNDTIMEO, seconds: seconds)
    }

    private func setTimeout(option: Int32, seconds: Double?) {
        guard let fd = activeDescriptor() else { return }
        let value = seconds ?? 0
        var timeout = timeval(
            tv_sec: Int(value),
            tv_usec: Int32((value - value.rounded(.down)) * 1_000_000)
        )
        setsockopt(
            fd, SOL_SOCKET, option,
            &timeout, socklen_t(MemoryLayout<timeval>.size)
        )
    }

    /// Appends a trailing newline and writes.
    public func writeLine(_ data: Data) throws {
        var payload = data
        payload.append(0x0A)
        try write(payload)
    }

    /// Raw write, no framing added. For callers that already hold a fully
    /// framed (newline-terminated) payload — e.g. a broadcast fan-out, where
    /// appending once up front avoids an append-triggered copy-on-write of
    /// the shared buffer on every recipient.
    public func write(_ data: Data) throws {
        guard let fd = activeDescriptor() else { throw UnixSocketError.closed }
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var sent = 0
            while sent < rawBuffer.count {
                let count = Darwin.write(fd, base.advanced(by: sent), rawBuffer.count - sent)
                if count < 0 {
                    // A signal delivered mid-write is not a broken link —
                    // readLine() already retries the equivalent read(2) case.
                    if errno == EINTR { continue }
                    throw UnixSocketError.systemCall("write", errno)
                }
                guard count > 0 else {
                    throw UnixSocketError.systemCall("write", errno)
                }
                sent += count
            }
        }
    }

    public func readLine() throws -> Data {
        while true {
            // A complete, already-buffered line is ALWAYS returned, no
            // matter how much other (not-yet-processed) data sits behind it
            // in the buffer — a burst read can pull one 16KB chunk holding
            // 100+ small messages, and rejecting the first one because the
            // 101st pushed the total over the cap would tear down a
            // perfectly healthy, ordinary connection.
            if let newline = readBuffer.firstIndex(of: 0x0A) {
                let line = readBuffer.prefix(upTo: newline)
                readBuffer.removeSubrange(...newline)
                return Data(line)
            }
            // No complete line buffered: only an UNTERMINATED fragment this
            // long is garbage, not legitimate traffic waiting on its
            // newline. Checked before every read (including the very first
            // one after an append), so a flood of no-newline garbage is
            // caught after at most one further read past the cap, not
            // several.
            guard readBuffer.count <= maxLineBytes else {
                throw UnixSocketError.lineTooLong(limit: maxLineBytes)
            }

            var bytes = [UInt8](repeating: 0, count: 16_384)
            guard let fd = activeDescriptor() else { throw UnixSocketError.closed }
            let count = Darwin.read(fd, &bytes, bytes.count)
            let readErrno = errno
            if count < 0 {
                if readErrno == EINTR { continue }
                throw UnixSocketError.systemCall("read", readErrno)
            }
            guard count > 0 else { throw UnixSocketError.closed }
            readBuffer.append(bytes, count: count)
        }
    }
}
