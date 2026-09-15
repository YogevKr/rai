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
    /// Runs on the pipeline thread after each chunk enters the parser, with
    /// the cursor read right after that parse. Subclasses set this once; it
    /// must not touch the view.
    var outputObserver: (@Sendable (ArraySlice<UInt8>, Position) -> Void)?

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
            cursor: TerminalCursorProbe(view: self),
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
        // Releasing the process arms SwiftTerm's SIGTERM-then-SIGKILL
        // escalation. The default half second cuts `herdr terminal attach`
        // off before it detaches its socket and restores the terminal mode.
        // Five seconds matches the graceful exit the old SIGTERM-only path
        // allowed. The output drain keeps its default timeout: the driver is
        // already stopped when rai terminates, so a longer drain buys nothing.
        process.killEscalationDelay = 5
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
///
/// `stop()` and the feed share one lock. A read that passed the stopped
/// check cannot be waiting for the terminal lock while `stop()` returns, so
/// a reset or a new session that follows `stop()` never receives old bytes.
final class TerminalProcessOutput: LocalProcessDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private let windowSize: winsize
    private let feed: TerminalFeedSender
    private let cursor: TerminalCursorProbe
    private let observe: (@Sendable (ArraySlice<UInt8>, Position) -> Void)?
    private let exited: @MainActor (Int32?) -> Void

    init(
        windowSize: winsize,
        feed: TerminalFeedSender,
        cursor: TerminalCursorProbe,
        observe: (@Sendable (ArraySlice<UInt8>, Position) -> Void)?,
        exited: @escaping @MainActor (Int32?) -> Void
    ) {
        self.windowSize = windowSize
        self.feed = feed
        self.cursor = cursor
        self.observe = observe
        self.exited = exited
    }

    /// Blocks until an in-flight feed returns. A feed parses at most one
    /// pipeline batch.
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
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        feed.feed(byteArray: slice)
        // The cursor right after this chunk parsed. A later chunk can move it
        // before the main hop runs, so the hop must not read it again.
        observe?(slice, cursor.read())
    }

    func getWindowSize() -> winsize { windowSize }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        DispatchQueue.main.async { [self] in
            guard !isStopped else { return }
            exited(exitCode)
        }
    }
}

/// Reads the cursor from any thread without retaining the view. One lock
/// acquisition, no row copies.
final class TerminalCursorProbe: @unchecked Sendable {
    private weak var view: TerminalView?

    init(view: TerminalView) {
        self.view = view
    }

    func read() -> Position {
        view?.cursorPosition ?? Position(col: 0, row: 0)
    }
}

/// Collects output chunks for prediction bookkeeping on one coalesced main
/// hop. The pipeline thread appends; at most one main task is pending.
/// A burst above `limit` drops the bytes and records an overflow, so the
/// main hop resets predictions instead of replaying the burst.
///
/// SwiftTerm marks the frame dirty before the observer appends, so the frame
/// that paints a chunk can land before the main hop runs. Each batch records
/// the display generation at its last append; the hop compares it with the
/// current generation to learn whether that frame already landed.
final class TerminalOutputBookkeeping: @unchecked Sendable {
    static let limit = 64 * 1024

    /// One parsed chunk and the cursor right after its parse.
    struct Chunk: Equatable {
        let bytes: [UInt8]
        let cursor: Position
    }

    struct Batch {
        let chunks: [Chunk]
        let overflowed: Bool
        /// The display generation when the last chunk was appended.
        let displayGeneration: UInt64
        var isEmpty: Bool { chunks.isEmpty && !overflowed }
        var bytes: [UInt8] { chunks.flatMap(\.bytes) }
    }

    private let lock = NSLock()
    private var chunks: [Chunk] = []
    private var byteCount = 0
    private var overflowed = false
    private var hopPending = false
    private var appendGeneration: UInt64 = 0
    private var frameGeneration: UInt64 = 0
    private let limit: Int
    private let drain: @MainActor () -> Void

    init(limit: Int = TerminalOutputBookkeeping.limit, drain: @escaping @MainActor () -> Void) {
        self.limit = limit
        self.drain = drain
    }

    /// Pipeline thread. Schedules the main hop when none is pending.
    func append(_ chunk: ArraySlice<UInt8>, cursor: Position) {
        lock.lock()
        if overflowed || byteCount + chunk.count > limit {
            overflowed = true
            chunks.removeAll(keepingCapacity: true)
            byteCount = 0
        } else {
            chunks.append(Chunk(bytes: Array(chunk), cursor: cursor))
            byteCount += chunk.count
        }
        appendGeneration = frameGeneration
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
        let batch = Batch(
            chunks: chunks, overflowed: overflowed, displayGeneration: appendGeneration
        )
        chunks.removeAll(keepingCapacity: true)
        byteCount = 0
        overflowed = false
        hopPending = false
        return batch
    }

    /// Main thread, once per prepared frame (`rangeChanged`).
    func noteFramePresented() {
        lock.lock()
        frameGeneration &+= 1
        lock.unlock()
    }

    /// The number of frames presented so far.
    var displayGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return frameGeneration
    }

    /// True when a frame landed after the batch's last chunk was appended.
    func framePresented(since batch: Batch) -> Bool {
        displayGeneration != batch.displayGeneration
    }

    /// Main thread. A pending hop then finds nothing to reconcile.
    func discard() {
        lock.lock()
        chunks.removeAll(keepingCapacity: true)
        byteCount = 0
        overflowed = false
        lock.unlock()
    }
}
