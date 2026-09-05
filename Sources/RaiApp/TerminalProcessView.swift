import AppKit
import SwiftTerm

@MainActor
protocol TerminalProcessViewDelegate: AnyObject {
    func sizeChanged(source: TerminalProcessView, newCols: Int, newRows: Int)
    func setTerminalTitle(source: TerminalProcessView, title: String)
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?)
    func processTerminated(source: TerminalView, exitCode: Int32?)
}

/// Owns the public SwiftTerm process API so output delivery can apply
/// backpressure until the main-thread parser has consumed each read.
class TerminalProcessView: TerminalView, TerminalViewDelegate {
    weak var processDelegate: TerminalProcessViewDelegate?
    private(set) var process: LocalProcess?
    private var outputDriver: TerminalProcessOutput?
    private var processGeneration: UInt64 = 0

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
        if process?.running == true { process?.terminate() }
    }

    func startProcess(
        executable: String = "/bin/bash", args: [String] = [],
        environment: [String]? = nil, execName: String? = nil,
        currentDirectory: String? = nil
    ) {
        guard process?.running != true else { return }
        outputDriver?.stop()
        discardPendingOutput()
        processGeneration &+= 1
        let generation = processGeneration
        let driver = TerminalProcessOutput(
            windowSize: getWindowSize(),
            receive: { [weak self] bytes, complete in
                guard let self, self.processGeneration == generation else {
                    complete()
                    return
                }
                self.dataReceived(slice: bytes[...], completion: complete)
            },
            exited: { [weak self] code in
                guard let self, self.processGeneration == generation else { return }
                self.processDelegate?.processTerminated(source: self, exitCode: code)
            }
        )
        outputDriver = driver
        let process = LocalProcess(
            delegate: driver,
            dispatchQueue: DispatchQueue(label: "rai.terminal-output", qos: .userInitiated)
        )
        self.process = process
        process.startProcess(
            executable: executable, args: args, environment: environment,
            execName: execName, currentDirectory: currentDirectory
        )
    }

    func terminate() {
        processGeneration &+= 1
        outputDriver?.stop()
        outputDriver = nil
        discardPendingOutput()
        if process?.running == true { process?.terminate() }
        process = nil
    }

    func discardPendingOutput() {}

    func dataReceived(slice: ArraySlice<UInt8>, completion: @escaping () -> Void = {}) {
        feed(byteArray: slice)
        completion()
    }

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
        let size = getTerminal().getDims()
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

/// SwiftTerm calls this delegate synchronously on a private output queue.
/// Waiting here bounds outstanding output to one PTY read (at most 128 KB).
/// Input writes use a separate DispatchIO path and never wait on this queue.
final class TerminalProcessOutput: LocalProcessDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var pending: DispatchSemaphore?
    private let windowSize: winsize
    private let receive: @MainActor ([UInt8], @escaping () -> Void) -> Void
    private let exited: @MainActor (Int32?) -> Void

    init(
        windowSize: winsize,
        receive: @escaping @MainActor ([UInt8], @escaping () -> Void) -> Void,
        exited: @escaping @MainActor (Int32?) -> Void
    ) {
        self.windowSize = windowSize
        self.receive = receive
        self.exited = exited
    }

    func stop() {
        lock.lock()
        stopped = true
        let pending = pending
        self.pending = nil
        lock.unlock()
        pending?.signal()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        let complete = DispatchSemaphore(value: 0)
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        pending = complete
        lock.unlock()
        let bytes = Array(slice)
        DispatchQueue.main.async { [self] in
            guard !isStopped else { complete.signal(); return }
            receive(bytes) { complete.signal() }
        }
        complete.wait()
        lock.lock()
        if pending === complete { pending = nil }
        lock.unlock()
    }

    func getWindowSize() -> winsize { windowSize }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        DispatchQueue.main.async { [self] in
            guard !isStopped else { return }
            exited(exitCode)
        }
    }
}
