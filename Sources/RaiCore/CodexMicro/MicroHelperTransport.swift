#if os(macOS)
import Darwin
import Foundation

/// What the MicroController worker needs from a pad link: monitoring with
/// attach/detach callbacks, input reports, and lighting writes. Implemented
/// directly over IOKit HID, and over the rai-microd helper socket for
/// macOS versions that refuse raw HID access to non-root processes.
public protocol MicroLink: AnyObject, Sendable {
    var onReport: (@Sendable ([UInt8]) -> Void)? { get set }
    var onConnectionChange: (@Sendable (Bool) -> Void)? { get set }
    var onDiagnostic: (@Sendable (String) -> Void)? { get set }
    /// A failure the user should see (Settings), unlike `onDiagnostic` traces.
    /// Fired for failures that cannot throw to the caller: hot-plug open
    /// failures on the IOKit link, and connect/handshake/pad-side failures on
    /// the helper link, whose monitoring loop retries instead of throwing.
    var onLinkError: (@Sendable (String) -> Void)? { get set }
    var currentDeviceIdentity: MicroDeviceIdentity? { get }
    func openMonitoring() throws
    func close()
    func send(report: [UInt8]) throws
}

extension IOHIDMicroTransport: MicroLink {}

/// Pad link over the rai-microd privileged helper's unix socket.
///
/// Mirrors `IOHIDMicroTransport.openMonitoring` semantics: callbacks are
/// delivered on the run loop `openMonitoring()` was called from, attach fires
/// when the pad appears (including already-present at connect), and the link
/// survives both pad drops and helper restarts by reconnecting with backoff.
public final class MicroHelperTransport: MicroLink, @unchecked Sendable {
    private let lock = NSLock()
    private let socketPath: String
    private var socket: UnixSocket?
    private var started = false
    private var stopped = false
    private var attachedIdentity: MicroDeviceIdentity?
    private var deliveryRunLoop: CFRunLoop?
    private var keepAliveSource: CFRunLoopSource?
    /// Counts sends since the last success, spanning reconnects (a fresh
    /// attach does NOT reset this — see the .attached case). A daemon that
    /// accepts connects and completes handshakes but never drains a
    /// client's writes (its reader thread wedged, say) would otherwise sit
    /// forever in the connect/handshake-succeeded branch that resets the
    /// once-per-outage latch — LEDs dark, no error, no signal to reinstall.
    /// This is the only thing that can detect that failure mode.
    private var consecutiveSendFailures = 0
    /// When the failure streak above was last extended. A genuinely wedged
    /// daemon fails every attempt close together in time (reconnects retry
    /// every couple seconds); three isolated, unrelated blips hours apart
    /// (rare BLE drop at 9am, USB jiggle at 2pm, ...) must NOT sum into the
    /// same "stuck" diagnosis just because no lighting update happened to
    /// occur in between to reset the count via a successful write.
    private var lastSendFailureAt: Date?
    private static let sendFailureStreakWindow: TimeInterval = 30

    private var reportCallback: (@Sendable ([UInt8]) -> Void)?
    private var connectionCallback: (@Sendable (Bool) -> Void)?
    private var diagnosticCallback: (@Sendable (String) -> Void)?
    private var linkErrorCallback: (@Sendable (String) -> Void)?

    public var onReport: (@Sendable ([UInt8]) -> Void)? {
        get { lock.withLock { reportCallback } }
        set { lock.withLock { reportCallback = newValue } }
    }

    public var onConnectionChange: (@Sendable (Bool) -> Void)? {
        get { lock.withLock { connectionCallback } }
        set { lock.withLock { connectionCallback = newValue } }
    }

    public var onDiagnostic: (@Sendable (String) -> Void)? {
        get { lock.withLock { diagnosticCallback } }
        set { lock.withLock { diagnosticCallback = newValue } }
    }

    public var onLinkError: (@Sendable (String) -> Void)? {
        get { lock.withLock { linkErrorCallback } }
        set { lock.withLock { linkErrorCallback = newValue } }
    }

    public var currentDeviceIdentity: MicroDeviceIdentity? {
        lock.withLock { attachedIdentity }
    }

    public init(socketPath: String = MicroHelperWire.defaultSocketPath) {
        self.socketPath = socketPath
    }

    /// True when the helper's socket exists at its well-known root-owned path.
    public static func helperSocketExists(
        socketPath: String = MicroHelperWire.defaultSocketPath
    ) -> Bool {
        UnixSocket.isSocketFile(atPath: socketPath)
    }

    public enum HelperProbe: Equatable {
        case available
        case notInstalled
        /// Helper is installed but launchd is (re)starting the daemon: no
        /// socket right now. The helper link's own reconnect loop is the
        /// right waiting room — falling back to direct HID here would pin a
        /// macOS 26.6 session to a dead link over a 5-second restart window.
        case installedNotRunning
        /// Socket file exists but the handshake fails — a stale file after
        /// an unclean daemon death, another user's install (the socket is
        /// chowned to one uid), a wedged daemon, or version skew. Committing
        /// to the helper here would pin the pad to a dead path forever; the
        /// caller should fall back to the direct link and surface the reason.
        case unreachable(String)
    }

    /// One full handshake (local unix socket, effectively instant) decides
    /// the link at worker start. A bare connect() is NOT proof of a live
    /// daemon: the kernel completes connects into the listen backlog even
    /// when the daemon is wedged, and a version-skewed daemon accepts
    /// connects it can never serve — both must fall back to the direct link,
    /// not capture the pad forever.
    public static func probeHelper(
        socketPath: String = MicroHelperWire.defaultSocketPath,
        launchDaemonPlistPath: String = MicroHelperWire.launchDaemonPlistPath
    ) -> HelperProbe {
        guard helperSocketExists(socketPath: socketPath) else {
            return FileManager.default.fileExists(atPath: launchDaemonPlistPath)
                ? .installedNotRunning
                : .notInstalled
        }
        let socket: UnixSocket
        do {
            socket = try UnixSocket(path: socketPath, maxLineBytes: MicroHelperWire.maxLineBytes)
        } catch UnixSocketError.systemCall("connect", let code) where code == ECONNREFUSED {
            // The socket FILE surviving an unclean daemon death (SIGKILL,
            // panic — only the graceful SIGTERM/SIGINT path unlinks it) is
            // indistinguishable from a normal launchd restart window; treat
            // both as "wait", not as a reason to fall back and warn.
            return FileManager.default.fileExists(atPath: launchDaemonPlistPath)
                ? .installedNotRunning
                : .unreachable("connection refused")
        } catch {
            return .unreachable(error.localizedDescription)
        }
        defer { socket.close() }
        switch performHandshake(on: socket) {
        case .completed:
            return .available
        case .failed(let reason):
            return .unreachable(reason)
        }
    }

    /// Which link the worker should build for a probe result. Pure policy,
    /// kept next to the probe it interprets so the rules and their
    /// enforcement cannot drift apart, and testable without hardware.
    ///
    /// The OS gate resolves an otherwise unwinnable tension: on macOS 26.6+
    /// the direct link is a silent black hole (input withheld for non-root
    /// processes), so any installed helper is worth waiting for; before 26.6
    /// the direct link WORKS, so a helper that does not answer right now must
    /// never capture the pad.
    public enum LinkChoice: Equatable {
        case helper
        case direct
        case directWithError(String)
    }

    public static func chooseLink(
        probe: HelperProbe,
        directHIDRestricted: Bool
    ) -> LinkChoice {
        switch probe {
        case .available:
            return .helper
        case .notInstalled:
            return .direct
        case .installedNotRunning:
            // 26.6+: wait out the daemon's restart window on the helper's
            // reconnect loop. Earlier macOS: the direct link works today,
            // and a helper that is not running should not block it.
            return directHIDRestricted ? .helper : .direct
        case .unreachable(let reason):
            // 26.6+: even a wedged/skewed helper beats the blocked direct
            // link — the helper link retries, self-heals, and reports its
            // outage. Earlier macOS: use the working direct link and say why.
            return directHIDRestricted ? .helper : .directWithError(reason)
        }
    }

    /// Whether this macOS withholds raw HID keyboard-class access from
    /// non-root processes (the 26.6 tightening).
    public static var directHIDRestricted: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 6, patchVersion: 0)
        )
    }

    enum HandshakeOutcome {
        case completed
        case failed(String)
    }

    /// The one hello/version exchange, shared by the probe and the live
    /// session so they can never disagree about what a healthy helper looks
    /// like. Reads under a receive timeout — the kernel completes connects
    /// into a wedged daemon's listen backlog, and an untimed greeting read
    /// would park the caller forever — and restores blocking reads after.
    static func performHandshake(on socket: UnixSocket) -> HandshakeOutcome {
        socket.setReceiveTimeout(1.0)
        defer { socket.setReceiveTimeout(nil) }
        guard let greeting = try? socket.readLine() else {
            return .failed("the helper accepted the connection but did not answer")
        }
        guard case .hello(let version)? = MicroHelperWire.decodeServerMessage(greeting) else {
            return .failed("the helper sent an invalid greeting")
        }
        guard version == MicroHelperWire.version else {
            return .failed(
                "the helper speaks protocol v\(version), this app v\(MicroHelperWire.version) "
                    + "— rebuild and reinstall the helper"
            )
        }
        return .completed
    }

    public func openMonitoring() throws {
        try lock.withLock {
            guard !started else { throw MicroTransportError.alreadyOpen }
            guard let runLoop = CFRunLoopGetCurrent() else {
                throw MicroTransportError.notOpen
            }
            started = true
            deliveryRunLoop = runLoop
            // The IOKit link keeps the caller's run loop alive by scheduling
            // the HID manager on it. This link installs no real sources —
            // deliveries arrive via CFRunLoopPerformBlock, which does NOT
            // count as a source — so without this placeholder the caller's
            // CFRunLoopRun() returns immediately and the link dies unused.
            var context = CFRunLoopSourceContext()
            context.perform = { _ in }
            let source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context)
            CFRunLoopAddSource(runLoop, source, CFRunLoopMode.defaultMode)
            keepAliveSource = source
        }
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "rai.micro-helper"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    public func close() {
        let (socket, source, runLoop): (UnixSocket?, CFRunLoopSource?, CFRunLoop?) =
            lock.withLock {
                stopped = true
                // Matches IOHIDMicroTransport.close() resetting `monitoring`:
                // a close/reopen cycle on the same instance must be able to
                // openMonitoring() again, not throw .alreadyOpen forever.
                // Unlike that sibling's fully synchronous teardown, this
                // transport's monitoring thread only notices `stopped` on
                // its next check (up to ~100ms, or immediate if blocked in a
                // read this shutdown() just interrupted) — reopening this
                // exact instance faster than that could race the OLD
                // thread's teardown. No current call site reuses an
                // instance across close/open (Worker.run() builds a fresh
                // transport every time), so this is latent, not live.
                started = false
                let current = self.socket
                self.socket = nil
                attachedIdentity = nil
                let source = keepAliveSource
                keepAliveSource = nil
                return (current, source, deliveryRunLoop)
            }
        socket?.close()
        if let source {
            CFRunLoopSourceInvalidate(source)
            if let runLoop {
                CFRunLoopRemoveSource(runLoop, source, CFRunLoopMode.defaultMode)
            }
        }
    }

    public func send(report: [UInt8]) throws {
        guard MicroHelperWire.isValidReport(report) else {
            throw MicroTransportError.invalidReport
        }
        let socket: UnixSocket? = lock.withLock {
            attachedIdentity != nil ? self.socket : nil
        }
        guard let socket else { throw MicroTransportError.notOpen }
        do {
            try socket.writeLine(MicroHelperWire.encode(.send(report: report)))
            lock.withLock { consecutiveSendFailures = 0 }
        } catch {
            // A failed write means the link is down or wedged. Force the
            // socket closed so the reader thread reconnects — a daemon that
            // reads nothing while still broadcasting would otherwise keep a
            // "healthy" session whose writes silently vanish.
            diagnose("helper write failed (\(error.localizedDescription)); reconnecting")
            socket.close()
            // A single failure is a routine timing race (the reconnect that
            // follows recovers it silently, matching the direct link's own
            // detach-gap race). Failures that persist ACROSS reconnects mean
            // the daemon is accepting connections but not actually serving —
            // that must reach Settings, or the pad stays dark forever with
            // no way for the user to know reinstalling would fix it.
            let now = Date()
            let persistentFailure = lock.withLock {
                let withinStreak = lastSendFailureAt
                    .map { now.timeIntervalSince($0) <= Self.sendFailureStreakWindow }
                    ?? false
                consecutiveSendFailures = withinStreak ? consecutiveSendFailures + 1 : 1
                lastSendFailureAt = now
                return consecutiveSendFailures == 3
            }
            if persistentFailure {
                reportLinkError(
                    "rai-microd accepts connections but pad writes keep failing; "
                        + "the helper may be stuck. "
                        + MicroHelperWire.reinstallOrRemoveHint
                )
            }
            throw MicroTransportError.notOpen
        }
    }

    private func run() {
        // One Settings-visible report per OUTAGE — latched across retries and
        // across connect-then-handshake-fail cycles (a version-skewed helper
        // accepts the connect and rejects the hello every 2 seconds; without
        // the latch that is a recordError storm for the app's lifetime).
        // Reset only by a completed handshake.
        var reportedOutage = false
        var consecutiveConnectFailures = 0
        while !lock.withLock({ stopped }) {
            let socket: UnixSocket
            do {
                socket = try UnixSocket(path: socketPath, maxLineBytes: MicroHelperWire.maxLineBytes)
            } catch {
                consecutiveConnectFailures += 1
                // A launchd (re)start window is a NORMAL state that lasts a
                // few seconds — flashing an error for it teaches the user to
                // ignore the panel. Report only an outage that persists.
                if !reportedOutage, consecutiveConnectFailures >= 5 {
                    reportLinkError(
                        "cannot reach rai-microd (\(error.localizedDescription)); "
                            + "is the helper running? "
                            + MicroHelperWire.reinstallOrRemoveHint
                    )
                    reportedOutage = true
                }
                sleepBeforeRetry()
                continue
            }
            consecutiveConnectFailures = 0
            // The daemon guards itself with SO_SNDTIMEO; mirror it here so a
            // daemon that stops draining can never park the worker's run-loop
            // thread inside a lighting write.
            socket.setSendTimeout(1.0)
            let installed: Bool = lock.withLock {
                guard !stopped else { return false }
                self.socket = socket
                return true
            }
            guard installed else {
                socket.close()
                return
            }
            switch serve(socket) {
            case .handshakeCompleted:
                reportedOutage = false
            case .handshakeFailed:
                // close() interrupting an in-flight handshake is shutdown,
                // not an outage — reporting it would leave a stale error in
                // Settings after every toggle-off.
                if !reportedOutage, !lock.withLock({ stopped }) {
                    reportLinkError(
                        "rai-microd handshake failed — the helper may be down "
                            + "or version-skewed. "
                            + MicroHelperWire.reinstallOrRemoveHint
                    )
                    reportedOutage = true
                }
            }
            let (wasAttached, stopping): (Bool, Bool) = lock.withLock {
                let attached = attachedIdentity != nil
                attachedIdentity = nil
                self.socket = nil
                return (attached, stopped)
            }
            socket.close()
            // A detach caused by OUR OWN close() (Worker.stop(), integration
            // toggled off) is shutdown, not a pad event — matches the
            // handshakeFailed branch's same reasoning just above.
            if wasAttached, !stopping { deliverConnectionChange(false) }
            sleepBeforeRetry()
        }
    }

    private enum ServeOutcome {
        case handshakeCompleted
        case handshakeFailed
    }

    /// Reads one session: handshake, then events until the socket drops.
    private func serve(_ socket: UnixSocket) -> ServeOutcome {
        guard case .completed = Self.performHandshake(on: socket) else {
            return .handshakeFailed
        }
        do {
            diagnose("connected to rai-microd")
            while true {
                let line = try socket.readLine()
                guard let message = MicroHelperWire.decodeServerMessage(line) else {
                    continue
                }
                switch message {
                case .hello:
                    continue
                case .attached(let identity):
                    let firstAttach: Bool = lock.withLock {
                        let wasDetached = attachedIdentity == nil
                        attachedIdentity = Self.deviceIdentity(for: identity)
                        // Deliberately NOT resetting consecutiveSendFailures
                        // here. Every failed send force-closes the socket
                        // (see send()) and the reconnect loop's own success
                        // always produces a fresh .attached — so resetting on
                        // attach made every single failure erase itself
                        // before a second one could accumulate, and the
                        // 3-strike escalation could never fire for the exact
                        // "daemon greets fine but never drains writes"
                        // scenario it exists to catch. Only a genuinely
                        // successful write (below) may reset the count.
                        return wasDetached
                    }
                    if firstAttach { deliverConnectionChange(true) }
                case .detached:
                    let wasAttached: Bool = lock.withLock {
                        let attached = attachedIdentity != nil
                        attachedIdentity = nil
                        return attached
                    }
                    if wasAttached { deliverConnectionChange(false) }
                case .report(let report):
                    deliverReport(report)
                case .error(let message):
                    // Pad-side failures the daemon saw (seized pad, refused
                    // writes). Already once-per-outage on the daemon side.
                    reportLinkError(message)
                }
            }
        } catch {
            if !lock.withLock({ stopped }) {
                diagnose("helper link dropped: \(error.localizedDescription)")
            }
            // Only reached after a completed handshake (a failed one returns
            // above), so the once-per-outage latch may reset.
            return .handshakeCompleted
        }
    }

    /// The panel shows this identity, so mark the link as helper-carried.
    static func deviceIdentity(for identity: MicroHelperIdentity) -> MicroDeviceIdentity {
        MicroDeviceIdentity(
            vendorID: identity.vendorID,
            productID: identity.productID,
            usagePage: 0x01,
            usagePairs: [
                MicroUsagePair(
                    usagePage: IOHIDMicroTransport.usagePage,
                    usage: IOHIDMicroTransport.usage
                ),
            ],
            manufacturer: identity.manufacturer,
            product: identity.product,
            transport: .other("\(identity.transportName) · rai-microd"),
            maxInputReportSize: MicroFraming.reportSize,
            maxOutputReportSize: MicroFraming.reportSize,
            registryEntryID: identity.registryEntryID
        )
    }

    /// Polls in short slices rather than one 2-second sleep, so a toggle-off
    /// mid-retry is noticed promptly instead of leaving this thread — and a
    /// stale run-loop delivery target — alive for up to 2 more seconds
    /// alongside the next toggle-on's fresh transport.
    private func sleepBeforeRetry() {
        for _ in 0..<20 {
            guard !lock.withLock({ stopped }) else { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    // Callbacks are delivered on the run loop openMonitoring() was called
    // from, matching IOHIDMicroTransport, so the worker's single-threaded
    // state stays single-threaded no matter which link is active.
    private func deliverReport(_ report: [UInt8]) {
        deliver { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.reportCallback }?(report)
        }
    }

    private func deliverConnectionChange(_ connected: Bool) {
        deliver { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.connectionCallback }?(connected)
        }
    }

    private func diagnose(_ message: String) {
        deliver { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.diagnosticCallback }?(message)
        }
    }

    /// Failures worth the Settings panel, not just the log. Also traced.
    private func reportLinkError(_ message: String) {
        deliver { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.diagnosticCallback }?(message)
            self.lock.withLock { self.linkErrorCallback }?(message)
        }
    }

    private func deliver(_ block: @escaping @Sendable () -> Void) {
        let runLoop = lock.withLock { deliveryRunLoop }
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }
}
#endif
