import AppKit
import Darwin
import SwiftTerm

@MainActor
protocol TerminalProcessViewDelegate: AnyObject {
    func visibilityChanged(source: TerminalProcessView)
    func sizeChanged(source: TerminalProcessView, newCols: Int, newRows: Int)
    func setTerminalTitle(source: TerminalProcessView, title: String)
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?)
    func processTerminated(source: TerminalView, exitCode: Int32?)
}

/// Owns the public SwiftTerm process API. Process output parses inline on
/// SwiftTerm's pipeline thread; only process exit and prediction bookkeeping
/// reach the main thread.
class TerminalProcessView: TerminalView, TerminalViewDelegate {
    weak var processDelegate: TerminalProcessViewDelegate?
    private(set) var process: LocalProcess?
    private var outputDriver: TerminalProcessOutput?
    private var processGeneration: UInt64 = 0
    /// Runs on the pipeline thread after each chunk enters the parser.
    /// Subclasses set this once; it must not touch the view.
    var outputObserver: (@Sendable (ArraySlice<UInt8>) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        terminalDelegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        terminalDelegate = self
    }

    deinit {
        outputDriver?.stop()
        // Releasing the process sends SIGTERM, escalates to SIGKILL after
        // its kill escalation delay, and reaps the child on its own thread.
        process?.terminate()
    }

    var isTerminalVisible: Bool {
        window != nil && !isHiddenOrHasHiddenAncestor
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        processDelegate?.visibilityChanged(source: self)
    }

    override func viewDidHide() {
        super.viewDidHide()
        processDelegate?.visibilityChanged(source: self)
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        processDelegate?.visibilityChanged(source: self)
    }

    func startProcess(
        executable: String = "/bin/bash", args: [String] = [],
        environment: [String]? = nil, execName: String? = nil,
        currentDirectory: String? = nil, rawInput: Bool = false
    ) {
        guard process?.running != true else { return }
        outputDriver?.stop()
        discardPendingOutput()
        processGeneration &+= 1
        let generation = processGeneration
        let driver = TerminalProcessOutput(
            windowSize: getWindowSize(),
            feed: feedSender,
            observe: outputObserver,
            exited: { [weak self] code in
                guard let self, self.processGeneration == generation else { return }
                self.processDelegate?.processTerminated(source: self, exitCode: code)
            }
        )
        outputDriver = driver
        // Direct delivery parses each pipeline batch on the pipeline thread.
        // SwiftTerm's ring of read buffers bounds the outstanding output.
        let process = LocalProcess(delegate: driver, dispatchQueue: nil, directDelivery: true)
        self.process = process
        process.startProcess(
            executable: executable, args: args, environment: environment,
            execName: execName, currentDirectory: currentDirectory
        )
        // Herdr enables raw input only after its socket handshake. Configure
        // this display-client PTY before returning to the event loop so early
        // control keys reach Herdr instead of the local terminal line editor.
        guard !rawInput || Self.enableRawInput(on: process.childfd) else {
            terminate()
            processDelegate?.processTerminated(source: self, exitCode: nil)
            return
        }
    }

    private static func enableRawInput(on descriptor: Int32) -> Bool {
        var attributes = termios()
        guard tcgetattr(descriptor, &attributes) == 0 else { return false }
        cfmakeraw(&attributes)
        return tcsetattr(descriptor, TCSANOW, &attributes) == 0
    }

    /// Stops feeding the view and signals the child. SwiftTerm reaps the
    /// child itself: its exit monitor reaps a normal exit, and releasing the
    /// process escalates to SIGKILL and reaps on a dedicated thread.
    func terminate() {
        processGeneration &+= 1
        outputDriver?.stop()
        outputDriver = nil
        discardPendingOutput()
        process?.terminate()
        process = nil
    }

    /// Drops host-side bookkeeping for output of a stopped process.
    func discardPendingOutput() {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        process?.send(data: data)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        if let process, process.running {
            var size = getWindowSize()
            _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: process.childfd, windowSize: &size)
        }
        processDelegate?.sizeChanged(source: self, newCols: newCols, newRows: newRows)
    }

    func getWindowSize() -> winsize {
        let size = terminalDimensions
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let frame = getOptimalFrameSize()
        return winsize(
            ws_row: UInt16(clamping: size.rows), ws_col: UInt16(clamping: size.cols),
            ws_xpixel: UInt16(clamping: Int(frame.width * scale)),
            ws_ypixel: UInt16(clamping: Int(frame.height * scale))
        )
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        processDelegate?.setTerminalTitle(source: self, title: title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        processDelegate?.hostCurrentDirectoryUpdate(source: source, directory: directory)
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([text as NSString])
    }

    func clipboardRead(source: TerminalView) -> Data? {
        NSPasteboard.general.string(forType: .string)?.data(using: .utf8)
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// SwiftTerm calls this delegate inline on its pipeline thread. Each chunk
/// parses before the next read is delivered, so the pipeline's own ring of
/// read buffers bounds outstanding output. The driver never touches the view:
/// it feeds through the view's sendable `feedSender` and hops to main only
/// for process exit.
final class TerminalProcessOutput: LocalProcessDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private let windowSize: winsize
    private let feed: TerminalFeedSender
    private let observe: (@Sendable (ArraySlice<UInt8>) -> Void)?
    private let exited: @MainActor (Int32?) -> Void

    init(
        windowSize: winsize,
        feed: TerminalFeedSender,
        observe: (@Sendable (ArraySlice<UInt8>) -> Void)?,
        exited: @escaping @MainActor (Int32?) -> Void
    ) {
        self.windowSize = windowSize
        self.feed = feed
        self.observe = observe
        self.exited = exited
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        guard !isStopped else { return }
        feed.feed(byteArray: slice)
        observe?(slice)
    }

    func getWindowSize() -> winsize { windowSize }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        DispatchQueue.main.async { [self] in
            guard !isStopped else { return }
            exited(exitCode)
        }
    }
}

/// Collects output chunks for prediction bookkeeping on one coalesced main
/// hop. The pipeline thread appends; at most one main task is pending.
/// A burst above `limit` drops the bytes and records an overflow, so the
/// main hop resets predictions instead of replaying the burst.
final class TerminalOutputBookkeeping: @unchecked Sendable {
    static let limit = 64 * 1024

    struct Batch {
        let bytes: [UInt8]
        let overflowed: Bool
        var isEmpty: Bool { bytes.isEmpty && !overflowed }
    }

    private let lock = NSLock()
    private var bytes: [UInt8] = []
    private var overflowed = false
    private var hopPending = false
    private let limit: Int
    private let drain: @MainActor () -> Void

    init(limit: Int = TerminalOutputBookkeeping.limit, drain: @escaping @MainActor () -> Void) {
        self.limit = limit
        self.drain = drain
    }

    /// Pipeline thread. Schedules the main hop when none is pending.
    func append(_ chunk: ArraySlice<UInt8>) {
        lock.lock()
        if overflowed || bytes.count + chunk.count > limit {
            overflowed = true
            bytes.removeAll(keepingCapacity: true)
        } else {
            bytes.append(contentsOf: chunk)
        }
        let schedule = !hopPending
        hopPending = true
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { drain() }
        }
    }

    /// Main thread. Returns everything since the previous take.
    func take() -> Batch {
        lock.lock()
        defer { lock.unlock() }
        let batch = Batch(bytes: bytes, overflowed: overflowed)
        bytes.removeAll(keepingCapacity: true)
        overflowed = false
        hopPending = false
        return batch
    }

    /// Main thread. A pending hop then finds nothing to reconcile.
    func discard() {
        lock.lock()
        bytes.removeAll(keepingCapacity: true)
        overflowed = false
        lock.unlock()
    }

    var pendingByteCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return bytes.count
    }
}
