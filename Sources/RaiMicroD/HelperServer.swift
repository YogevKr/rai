import Darwin
import Foundation
import RaiCore

/// Serves the Codex Micro to local rai instances over a unix socket.
///
/// Security posture: the socket file is root-owned, mode 0600, chowned to the
/// single allowed uid; every accepted peer is re-checked with getpeereid; the
/// only accepted request is a validated 64-byte report-ID-6 frame for THIS
/// pad's vendor channel, rate-limited. The daemon can never be steered at any
/// other HID device.
final class HelperServer {
    private let socketPath: String
    private let allowedUID: uid_t
    /// Generously above any legitimate use (one rai instance, plus overlap
    /// during a reconnect): a bound so a runaway client cannot exhaust the
    /// daemon's fds/threads.
    private static let maxClients = 8

    /// Guards clients, the pad transport, and the last-known attach state.
    /// Broadcasts and the greeting on connect ENQUEUE under it — writes happen
    /// on per-client writer threads — so a client can never observe attach
    /// events out of order with its initial snapshot, and a wedged client
    /// never stalls the lock.
    private let stateLock = NSLock()
    private var clients: [ClientConnection] = []
    /// Why the pad is not attached, when the daemon knows (open blocked by a
    /// seizing process, say). Greeted to new clients and broadcast on change,
    /// because the daemon's own log is root-owned and invisible in Settings.
    /// Also the dedup latch: BLE re-enumeration can retry-and-fail every few
    /// hundred ms, and re-broadcasting the same reason each time would spam
    /// every client's Settings with a fresh recordError per attempt.
    private var lastPadError: String?
    private var transport: IOHIDMicroTransport?

    private var listenerFD: Int32 = -1
    private var lockFD: Int32 = -1
    /// The socket file THIS instance bound, by identity — cleanup must never
    /// unlink a socket a newer instance owns.
    private var boundSocket: (device: dev_t, inode: ino_t)?
    private var terminationSources: [DispatchSourceSignal] = []

    init(socketPath: String, allowedUID: uid_t) {
        self.socketPath = socketPath
        self.allowedUID = allowedUID
    }

    func run() throws {
        try acquireInstanceLock()
        try bindListener()
        installTerminationHandlers()

        let acceptThread = Thread { [weak self] in self?.acceptLoop() }
        acceptThread.name = "rai-microd.accept"
        acceptThread.start()

        openPadMonitoring()
        Self.log("monitoring for Codex Micro; socket \(socketPath), uid \(allowedUID)")
        CFRunLoopRun()
    }

    /// Unlinks the socket file if it is still the one this process bound.
    /// Called on exits so a leftover socket cannot strand rai on a helper
    /// that is gone — while never deleting a newer instance's live socket.
    func cleanup() {
        guard let boundSocket else { return }
        var status = stat()
        guard stat(socketPath, &status) == 0,
              status.st_dev == boundSocket.device,
              status.st_ino == boundSocket.inode else {
            return
        }
        unlink(socketPath)
    }

    /// One daemon per socket path. A second instance (hand-run while the
    /// launchd one lives, say) exits before it can unlink the live socket.
    private func acquireInstanceLock() throws {
        let lockPath = socketPath + ".lock"
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw UnixSocketError.systemCall("open lock", errno) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw HelperServerError.alreadyRunning(socketPath)
        }
        lockFD = fd
    }

    // MARK: - Pad link

    /// Opening can fail while the pad is seized by another privileged process.
    /// That is an environment state, not a daemon defect — exiting would make
    /// launchd's KeepAlive spin a crash loop — so retry on the main run loop
    /// with a fresh transport per attempt until one sticks, and tell clients
    /// why the pad is absent meanwhile. Later attach and drop cycles are the
    /// transport's own monitoring job.
    private func openPadMonitoring() {
        while true {
            let transport = IOHIDMicroTransport()
            configure(transport)
            // Published BEFORE calling openMonitoring(), which can attach
            // synchronously (a pad already present at open time) and fire
            // onConnectionChange before it even returns. The accept thread
            // starts before this loop's first iteration (so clients get fast
            // handshakes even while waiting out a seized pad) — a client
            // greeted in that window must see this object, or an
            // already-attached pad reads as absent until a later event.
            stateLock.withLock { self.transport = transport }
            do {
                try transport.openMonitoring()
                stateLock.withLock { lastPadError = nil }
                return
            } catch {
                reportPadError("the helper cannot open the pad: \(Self.padOpenFailureText(error))")
                transport.close()
                // Keep the run loop turning so SIGTERM stays responsive
                // during the retry window.
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 5))
            }
        }
    }

    /// This daemon IS the privileged helper — `MicroTransportError`'s
    /// kIOReturnNotPermitted wording ("install the privileged helper") is
    /// written for a non-root caller and would be circular/confusing coming
    /// from the helper itself, so it's substituted here if this code ever
    /// somehow hits that IOReturn while already running as root.
    private static func padOpenFailureText(_ error: Error) -> String {
        if let transportError = error as? MicroTransportError, transportError.isNotPermitted {
            return "IOKit refused HID access even to this privileged (root) helper "
                + "— check code signing/entitlements, or that no sandboxing "
                + "profile applies to rai-microd."
        }
        return error.localizedDescription
    }

    /// Once-per-distinct-reason reporting, shared by the initial-open retry
    /// loop and hot-plug attach failures — without the latch, BLE
    /// re-enumeration (documented as retrying every few hundred ms) would
    /// re-broadcast the same reason to every client on each attempt.
    private func reportPadError(_ message: String) {
        let alreadyReported: Bool = stateLock.withLock {
            let already = lastPadError == message
            lastPadError = message
            return already
        }
        guard !alreadyReported else { return }
        Self.log(message)
        broadcast(.error(message))
    }

    private func configure(_ transport: IOHIDMicroTransport) {
        transport.onDiagnostic = { message in Self.log("hid: \(message)") }
        // The hot-plug analog of openPadMonitoring's catch: a pad that
        // arrives while another process holds it fails here, not at open
        // time, and clients must hear about it or the failure lives only in
        // this daemon's root-owned log.
        transport.onLinkError = { [weak self] message in
            self?.reportPadError("the helper cannot open the pad: \(message)")
        }
        transport.onReport = { [weak self] report in
            self?.broadcast(.report(report))
        }
        transport.onConnectionChange = { [weak self, weak transport] connected in
            guard let self else { return }
            if connected {
                let identity = transport?.currentDeviceIdentity.map(Self.helperIdentity)
                Self.log("pad attached: \(identity?.transportName ?? "<unknown link>")")
                self.stateLock.withLock { self.lastPadError = nil }
                if let identity { self.broadcast(.attached(identity)) }
            } else {
                Self.log("pad detached")
                self.broadcast(.detached)
            }
        }
    }

    // MARK: - Listener

    private func bindListener() throws {
        if UnixSocket.isSocketFile(atPath: socketPath) {
            unlink(socketPath)
        } else if FileManager.default.fileExists(atPath: socketPath) {
            // Replace only what we own. A regular file squatting on the path
            // is a misconfiguration, never something to delete.
            throw HelperServerError.pathOccupied(socketPath)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError.systemCall("socket", errno) }

        let address: sockaddr_un
        do {
            address = try UnixSocket.makeAddress(path: socketPath)
        } catch {
            close(fd)
            throw error
        }

        // The socket is born inaccessible (umask), then handed to the one
        // allowed uid. Peers are also re-checked at accept, so the file mode
        // is defense in depth rather than the only gate.
        let previousMask = umask(0o077)
        let bindResult = withUnsafePointer(to: address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previousMask)
        guard bindResult == 0 else {
            let code = errno
            close(fd)
            throw UnixSocketError.systemCall("bind", code)
        }
        guard chown(socketPath, allowedUID, 0) == 0,
              chmod(socketPath, 0o600) == 0 else {
            let code = errno
            close(fd)
            unlink(socketPath)
            throw UnixSocketError.systemCall("chown/chmod", code)
        }
        guard listen(fd, 4) == 0 else {
            let code = errno
            close(fd)
            unlink(socketPath)
            throw UnixSocketError.systemCall("listen", code)
        }
        listenerFD = fd
        var bound = stat()
        if stat(socketPath, &bound) == 0 {
            boundSocket = (device: bound.st_dev, inode: bound.st_ino)
        }
    }

    private func acceptLoop() {
        while true {
            let fd = accept(listenerFD, nil, nil)
            guard fd >= 0 else {
                if errno == EINTR { continue }
                // EBADF/EINVAL mean the listener itself is gone. Everything
                // else (EMFILE/ENFILE/ECONNABORTED under pressure) is
                // transient — returning here would leave a live daemon that
                // can never accept again, with clients hanging silently.
                if errno == EBADF || errno == EINVAL {
                    Self.log("accept failed, listener gone: \(String(cString: strerror(errno)))")
                    return
                }
                Self.log("accept failed, retrying: \(String(cString: strerror(errno)))")
                Thread.sleep(forTimeInterval: 1)
                continue
            }
            var peerUID: uid_t = 0
            var peerGID: gid_t = 0
            // Exactly the one uid the socket is chowned to — matches this
            // class's documented "single allowed uid" trust boundary. No
            // root exception: nothing legitimate needs to drive the pad's
            // vendor HID channel as a socket client while running as root.
            guard getpeereid(fd, &peerUID, &peerGID) == 0,
                  peerUID == allowedUID else {
                Self.log("rejected peer uid \(peerUID)")
                close(fd)
                continue
            }
            // The allowed uid legitimately runs one rai instance; a small
            // cap survives a stray extra connection (retry overlap, a second
            // instance) without letting a runaway client (buggy retry loop,
            // or anything else running as this uid) accumulate reader/writer
            // threads and fds without bound.
            guard stateLock.withLock({ clients.count }) < Self.maxClients else {
                Self.log("rejected connection: \(Self.maxClients) clients already connected")
                close(fd)
                continue
            }

            // A client that stops reading must never wedge the daemon: its
            // writer thread's writes time out and the client is dropped.
            let client = ClientConnection(fd: fd)
            let greeted: Bool = stateLock.withLock {
                var greeted = client.enqueue(.hello(version: MicroHelperWire.version))
                // Identity is read LIVE from the transport: its node-upgrade
                // path (BLE node replacing a USB fallback) swaps devices
                // without firing onConnectionChange, so any cached snapshot
                // goes stale.
                let identity = transport?.currentDeviceIdentity.map(Self.helperIdentity)
                if greeted, let identity {
                    greeted = client.enqueue(.attached(identity))
                } else if greeted, let lastPadError {
                    greeted = client.enqueue(.error(lastPadError))
                }
                guard greeted else { return false }
                clients.append(client)
                return true
            }
            guard greeted else {
                client.shutdown()
                continue
            }
            client.startWriter { [weak self] in self?.remove(client, reason: "write failed") }
            Self.log("client connected (uid \(peerUID))")

            let reader = Thread { [weak self] in self?.readLoop(client) }
            reader.name = "rai-microd.client"
            reader.start()
        }
    }

    // MARK: - Clients

    private func readLoop(_ client: ClientConnection) {
        var malformedStrikes = 0
        while true {
            guard let line = client.readLine() else { break }
            let message: MicroHelperWire.ClientMessage
            switch MicroHelperWire.classifyClientLine(line) {
            case .message(let decoded):
                message = decoded
                malformedStrikes = 0
            case .unknownType:
                // A NEWER peer using the documented evolution path; tolerate
                // — and reset the strike counter, since this line was
                // structurally VALID, not malformed. Without the reset,
                // malformed lines interleaved with tolerated-but-unrelated
                // unknownType lines could still add up to a "repeated
                // malformed input" disconnect despite never being repeated.
                malformedStrikes = 0
                continue
            case .malformed:
                malformedStrikes += 1
                if malformedStrikes >= 3 {
                    return remove(client, reason: "repeated malformed input")
                }
                continue
            }
            switch message {
            case .send(let report):
                // Drop the frame, not the client: a legitimate burst (fast
                // dial scrolling during status churn can approach 64/s) must
                // not blow away the whole link over a 2-second reconnect —
                // that reads as the pad going dead for something routine.
                // The budget is per-client (not aggregated across the small
                // `maxClients` cap) — in normal operation there is exactly
                // one real client, so this still bounds the USB write path
                // in practice; it does not enforce a hard pad-wide ceiling
                // if multiple clients were ever simultaneously adversarial.
                guard client.sendBudget.consume() else { continue }
                let transport = stateLock.withLock { self.transport }
                do {
                    // `transport` can be nil in the narrow window between
                    // the accept thread starting and openPadMonitoring()'s
                    // first assignment — `try transport?.send` would
                    // silently swallow that (optional chaining never
                    // throws), falsely marking the send as ok. Route it
                    // through the SAME notOpen handling as a real not-open
                    // transport: both are "no pad link right now", already
                    // handled correctly below.
                    guard let transport else { throw MicroTransportError.notOpen }
                    try transport.send(report: report)
                    client.reportedWriteFailure = false
                } catch MicroTransportError.notOpen {
                    // Pad detached mid-flight; the detached event already in
                    // flight is the client's signal.
                } catch {
                    Self.log("pad write failed: \(error.localizedDescription)")
                    // Tell the failing client once per failure streak, or a
                    // persistently refusing pad shows dark LEDs with no error
                    // anywhere the user can see.
                    if !client.reportedWriteFailure {
                        client.reportedWriteFailure = true
                        _ = client.enqueue(
                            .error("pad write failed: \(error.localizedDescription)")
                        )
                    }
                }
            }
        }
        remove(
            client,
            reason: client.lastReadFailureReason.map { "disconnected (\($0))" } ?? "disconnected"
        )
    }

    private func remove(_ client: ClientConnection, reason: String) {
        let removed: Bool = stateLock.withLock {
            guard let index = clients.firstIndex(where: { $0 === client }) else {
                return false
            }
            clients.remove(at: index)
            return true
        }
        client.shutdown()
        if removed { Self.log("client \(reason)") }
    }

    /// Enqueue-only under the lock; per-client writer threads do the IO, so a
    /// stalled peer can delay nothing but itself. Encoded once — the input-
    /// report path runs through here per HID report, and re-encoding per
    /// client would pay N JSON+base64 passes under the lock. Overflowing a
    /// client's queue marks it for removal.
    private func broadcast(_ message: MicroHelperWire.ServerMessage) {
        var payload: Data
        do {
            payload = try MicroHelperWire.encode(message)
        } catch {
            // Should not happen for anything this daemon constructs itself
            // (it only ever encodes what it just validated or built) — if it
            // ever does, a miswired report would otherwise vanish with zero
            // trace anywhere, including this log.
            Self.log("broadcast: dropped unencodable message: \(error.localizedDescription)")
            return
        }
        payload.append(0x0A)
        let overflowed: [ClientConnection] = stateLock.withLock {
            clients.filter { !$0.enqueue(framedPayload: payload) }
        }
        for client in overflowed {
            remove(client, reason: "dropped: outbound queue overflow")
        }
    }

    // MARK: - Lifecycle

    private func installTerminationHandlers() {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        for signalNumber in [SIGTERM, SIGINT] {
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber, queue: .main
            )
            source.setEventHandler { [weak self] in
                Self.log("terminating")
                self?.cleanup()
                exit(0)
            }
            source.resume()
            terminationSources.append(source)
        }
    }

    static func helperIdentity(for identity: MicroDeviceIdentity) -> MicroHelperIdentity {
        MicroHelperIdentity(
            vendorID: identity.vendorID,
            productID: identity.productID,
            manufacturer: identity.manufacturer,
            product: identity.product,
            transportName: identity.transport.displayName,
            registryEntryID: identity.registryEntryID
        )
    }

    /// DateFormatter construction is expensive and log() sits on per-message
    /// paths (every hid trace, every refused write); one cached instance —
    /// DateFormatter is thread-safe for formatting on modern macOS.
    private static let logTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    /// log() is called from the accept thread, every client's reader/writer
    /// threads, and the IOHID callback thread — without serializing the
    /// writes, concurrent failures (exactly when the log matters most) can
    /// interleave partial lines in the root-owned log file.
    private static let logLock = NSLock()

    static func log(_ message: String) {
        let line = Data("[\(logTimestampFormatter.string(from: Date()))] \(message)\n".utf8)
        logLock.withLock {
            FileHandle.standardOutput.write(line)
        }
    }
}

enum HelperServerError: Error, LocalizedError {
    case pathOccupied(String)
    case alreadyRunning(String)

    var errorDescription: String? {
        switch self {
        case .pathOccupied(let path):
            "\(path) exists and is not a socket; refusing to replace it"
        case .alreadyRunning(let path):
            "another rai-microd already serves \(path); refusing to start"
        }
    }
}

/// One accepted client. Line framing is `UnixSocket`'s; outbound messages go
/// through a bounded queue drained by a dedicated writer thread, so the
/// daemon's broadcast path never blocks on a peer.
final class ClientConnection {
    /// Far above any legitimate burst (a full lighting repaint is 5 frames;
    /// input events broadcast one at a time); a reader this far behind is
    /// gone, not slow.
    private static let maxQueuedMessages = 256

    private let socket: UnixSocket
    private let queueCondition = NSCondition()
    private var outbound: [Data] = []
    private var closed = false
    let sendBudget = TokenBucket(capacity: 128, refillPerSecond: 64)
    /// Latches the pad-write-failure report per failure streak. Touched only
    /// by this client's reader thread.
    var reportedWriteFailure = false

    init(fd: Int32) {
        socket = UnixSocket(adoptingDescriptor: fd, maxLineBytes: MicroHelperWire.maxLineBytes)
        // A client that stops reading must never wedge the daemon: writes
        // time out and the client is dropped.
        socket.setSendTimeout(1.0)
    }

    /// nil on EOF, error, or an over-long line.
    /// Set right before `readLine()` returns nil, so a caller can log WHY
    /// the client dropped — an ordinary close and a peer flooding an
    /// unterminated line past the cap look identical as a bare `nil`
    /// otherwise, and the latter is a protocol-abuse signal worth keeping
    /// distinct from routine disconnect churn in the log.
    private(set) var lastReadFailureReason: String?

    func readLine() -> Data? {
        do {
            return try socket.readLine()
        } catch {
            lastReadFailureReason = error.localizedDescription
            return nil
        }
    }

    /// False when the client must be dropped (queue overflow or closed).
    /// Ordering across enqueue calls is the delivery order.
    func enqueue(_ message: MicroHelperWire.ServerMessage) -> Bool {
        guard var payload = try? MicroHelperWire.encode(message) else { return false }
        payload.append(0x0A)
        return enqueue(framedPayload: payload)
    }

    /// Takes an ALREADY newline-terminated payload — the broadcast path
    /// encodes and terminates once for every recipient, so appending here
    /// per client would force a copy-on-write of the shared `Data` on each
    /// call and defeat that.
    func enqueue(framedPayload: Data) -> Bool {
        queueCondition.lock()
        defer { queueCondition.unlock() }
        guard !closed, outbound.count < Self.maxQueuedMessages else { return false }
        outbound.append(framedPayload)
        queueCondition.signal()
        return true
    }

    /// `onFailure` fires once, off the daemon's broadcast path, when a write
    /// fails; the owner is expected to remove and shut down this client.
    func startWriter(onFailure: @escaping () -> Void) {
        // Captured strongly, not weakly: `onFailure` (built at the call site
        // as `{ [weak self] in self?.remove(client, ...) }`) already holds a
        // strong reference to THIS client for as long as this thread runs,
        // so a weak self here could never actually observe nil — it would
        // only mislead a future reader into thinking early deallocation is
        // handled. The thread's own loop is what ends this object's need to
        // stay alive (on `closed` or a write failure), not ARC racing it.
        let thread = Thread { [self] in
            while true {
                queueCondition.lock()
                while outbound.isEmpty, !closed {
                    queueCondition.wait()
                }
                guard !closed else {
                    queueCondition.unlock()
                    return
                }
                let payload = outbound.removeFirst()
                queueCondition.unlock()
                do {
                    try socket.write(payload)
                } catch {
                    onFailure()
                    return
                }
            }
        }
        thread.name = "rai-microd.writer"
        thread.start()
    }

    func shutdown() {
        queueCondition.lock()
        closed = true
        outbound.removeAll()
        queueCondition.broadcast()
        queueCondition.unlock()
        socket.close()
    }
}

/// Simple token bucket; thread-safe. Bounds how fast one client may push
/// frames at the pad, so a runaway client cannot wedge the USB link.
final class TokenBucket {
    private let lock = NSLock()
    private let capacity: Double
    private let refillPerSecond: Double
    private var tokens: Double
    private var lastRefill = Date()

    init(capacity: Double, refillPerSecond: Double) {
        self.capacity = capacity
        self.refillPerSecond = refillPerSecond
        tokens = capacity
    }

    func consume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        // A backward wall-clock step (NTP correction, manual change) must
        // never look like negative elapsed time — that would refill by a
        // negative amount and could drive tokens arbitrarily negative, with
        // no floor, locking this client out far past the intended budget.
        let elapsed = max(0, now.timeIntervalSince(lastRefill))
        tokens = min(capacity, max(0, tokens) + elapsed * refillPerSecond)
        lastRefill = now
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}
