import AppKit
import Foundation
import MetalKit
import QuartzCore
import RaiCore
import SwiftTerm

/// Renderer A/B harness for the terminal panes.
///
/// CPU% on the live app cannot isolate the renderer: pane count and agent
/// output both drift. This drives a fixed byte corpus into a fixed number of
/// panes, at a fixed rate, for a fixed wall time — so the only variable left is
/// CoreGraphics vs Metal.
///
///     swift run rai-bench --panes 4 --renderer metal
///     swift run rai-bench --panes 4 --renderer cg
///
/// Reports CPU seconds consumed over the measurement window. Lower is better.
///
/// Known limitation: the feed timer runs on the main thread, the same thread
/// the renderer draws on, so a slow enough renderer could in principle starve
/// its own input and under-report its cost. Check `fed=` across the runs you
/// are comparing — if it differs, the comparison is void. It has held equal
/// (2.9MB at 1 and 9 panes, all three renderers) in every run so far.
/// A warmup window is excluded so glyph-atlas population and the first window
/// display do not land in the number.

// MARK: - Options

struct Options {
    var panes = 4
    var useMetal = true
    var seconds = 20.0
    var warmup = 3.0
    var bytesPerSecond = 200_000
    var corpusPath: String?
    var aggregated = true
    var cols = 100
    var rows = 32
    var latency = false
    var latencySamples = 200
    var rendererSpecified = false
    var metalPresentsWithTransaction = false
    var metalDisplaySync = true
    var latencyFastPath = true

    static func parse(_ args: [String]) -> Options {
        var o = Options()
        var i = 0
        while i < args.count {
            let arg = args[i]
            func value() -> String? {
                i += 1
                return i < args.count ? args[i] : nil
            }
            switch arg {
            case "--panes": o.panes = Int(value() ?? "") ?? o.panes
            case "--renderer":
                o.useMetal = (value() ?? "metal") != "cg"
                o.rendererSpecified = true
            case "--seconds": o.seconds = Double(value() ?? "") ?? o.seconds
            case "--warmup": o.warmup = Double(value() ?? "") ?? o.warmup
            case "--rate": o.bytesPerSecond = Int(value() ?? "") ?? o.bytesPerSecond
            case "--corpus": o.corpusPath = value()
            case "--buffering": o.aggregated = (value() ?? "aggregated") != "per-row"
            case "--cols": o.cols = Int(value() ?? "") ?? o.cols
            case "--rows": o.rows = Int(value() ?? "") ?? o.rows
            case "--latency": o.latency = true
            case "--samples": o.latencySamples = Int(value() ?? "") ?? o.latencySamples
            case "--no-fast-path": o.latencyFastPath = false
            case "--metal-presents-with-transaction": o.metalPresentsWithTransaction = true
            case "--metal-display-sync": o.metalDisplaySync = (value() ?? "on") != "off"
            case "--help", "-h":
                print("""
                rai-bench — CoreGraphics vs Metal pane rendering

                  --panes N        panes in the grid (default 4)
                  --renderer R     metal | cg (default metal)
                  --seconds S      measurement window (default 20)
                  --warmup S       excluded warmup before measuring (default 3)
                  --rate B         bytes/second fed across all panes (default 200000)
                  --corpus PATH    replay these bytes (default: synthetic TUI-like output)
                  --buffering B    aggregated | per-row (default aggregated,
                                   matching what the app enables)
                  --cols / --rows  per-pane grid size (default 100x32)
                  --latency        measure byte feed and predictive overlay latency
                  --samples N      samples per latency path (default 200)
                  --no-fast-path   keep terminal echoes on SwiftTerm's path
                  --metal-presents-with-transaction
                                   present Metal frames with Core Animation transactions
                  --metal-display-sync on|off
                                   Metal display synchronization (default on)
                """)
                exit(0)
            default: break
            }
            i += 1
        }
        if o.latency && !o.rendererSpecified {
            // The app defaults to CoreGraphics. Keep bare --latency aligned
            // with production while preserving Metal as the CPU-mode default.
            o.useMetal = false
        }
        return o
    }
}

// MARK: - Typing latency

@MainActor
private func metalView(in view: NSView) -> MTKView? {
    for child in view.subviews {
        if let metal = child as? MTKView {
            return metal
        }
        if let nested = metalView(in: child) {
            return nested
        }
    }
    return nil
}

@MainActor
private final class LatencyTerminalDelegate: NSObject, @preconcurrency TerminalViewDelegate {
    var onRangeChanged: (() -> Void)?
    var onSend: ((ArraySlice<UInt8>) -> Void)?

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) { onSend?(data) }
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        onRangeChanged?()
    }
}

/// Measures the two latency paths controlled by rai. Both results end at a
/// draw callback after the terminal or prediction overlay draws. Each sample
/// waits for its own callback, so a prior frame cannot satisfy a later sample.
@MainActor
final class LatencyBenchDelegate: NSObject, NSApplicationDelegate {
    private enum Phase {
        case settling
        case terminal
        case prediction
        case finished
    }

    private let options: Options
    private let terminalDelegate = LatencyTerminalDelegate()
    private let prediction = PredictiveEchoEngine(displayLatencyThreshold: 0.008)
    private var window: NSWindow!
    private var terminalView: TerminalView!
    private var overlay: PredictionOverlayView!
    private var phase = Phase.settling
    private var sampleStart: UInt64?
    private var currentByte: UInt8 = 0x61
    private var terminalSamples: [Double] = []
    private var predictionSamples: [Double] = []
    private var terminalRepaintState = TerminalFeedRepaintState()

    nonisolated init(options: Options) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        print(
            "latency-config renderer=\(options.useMetal ? "metal" : "coregraphics") "
                + "presentsWithTransaction=\(options.metalPresentsWithTransaction) "
                + "displaySync=\(options.metalDisplaySync) "
                + "fastPath=\(options.latencyFastPath)"
        )
        terminalDelegate.onRangeChanged = { [weak self] in
            self?.terminalDisplayDidUpdate()
        }
        terminalDelegate.onSend = { [weak self] data in
            self?.terminalDidSend(data)
        }
        overlay.onDraw = { [weak self] in
            self?.predictionOverlayDidDraw()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.startTerminalSamples()
        }
    }

    private func buildWindow() {
        let size = NSSize(width: 720, height: 420)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "rai-bench latency"
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = content

        terminalView = TerminalView(frame: content.bounds)
        terminalView.autoresizingMask = [.width, .height]
        terminalView.notifyUpdateChanges = true
        terminalView.terminalDelegate = terminalDelegate
        content.addSubview(terminalView)

        overlay = PredictionOverlayView(
            frame: NSRect(x: 10, y: 10, width: 24, height: 24)
        )
        overlay.cellWidth = 12
        overlay.glyphFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        overlay.textColor = .labelColor
        overlay.cellBackground = .windowBackgroundColor
        overlay.isHidden = true
        content.addSubview(overlay)

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(terminalView)
        NSApp.activate(ignoringOtherApps: true)
        configureMetalIfNeeded()
    }

    private func configureMetalIfNeeded() {
        guard options.useMetal else { return }
        do {
            terminalView.metalBufferingMode = options.aggregated
                ? .perFrameAggregated
                : .perRowPersistent
            try terminalView.setUseMetal(true)
        } catch {
            FileHandle.standardError.write(Data("rai-bench: Metal unavailable: \(error)\n".utf8))
            exit(2)
        }
        guard let layer = metalView(in: terminalView)?.layer as? CAMetalLayer else {
            FileHandle.standardError.write(Data("rai-bench: Metal layer unavailable\n".utf8))
            exit(2)
        }
        layer.presentsWithTransaction = options.metalPresentsWithTransaction
        layer.displaySyncEnabled = options.metalDisplaySync
    }

    private func startTerminalSamples() {
        phase = .terminal
        runNextTerminalSample()
    }

    private func runNextTerminalSample() {
        guard terminalSamples.count < max(1, options.latencySamples) else {
            report("terminal-key-to-display-update", samples: terminalSamples)
            primePrediction()
            return
        }
        currentByte = 0x61 + UInt8(terminalSamples.count % 26)
        sampleStart = DispatchTime.now().uptimeNanoseconds
        terminalView.keyDown(with: syntheticKeyEvent(byte: currentByte))
    }

    private func terminalDidSend(_ data: ArraySlice<UInt8>) {
        guard phase == .terminal, sampleStart != nil else { return }
        guard options.latencyFastPath else {
            terminalView.feed(byteArray: data)
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        terminalRepaintState.noteUserInput(at: now)
        let disposition = terminalRepaintState.disposition(
            byteCount: data.count,
            isFocused: true,
            isVisible: true,
            synchronizedOutputActive: false,
            at: now
        )
        terminalView.feed(byteArray: data)
        if disposition == .feedNowAndRepaint {
            terminalView.needsDisplay = true
            terminalView.displayIfNeeded()
        }
    }

    private func terminalDisplayDidUpdate() {
        guard phase == .terminal, let start = sampleStart else { return }
        sampleStart = nil
        terminalSamples.append(milliseconds(since: start))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.020) { [weak self] in
            self?.runNextTerminalSample()
        }
    }

    private func primePrediction() {
        phase = .settling
        let now = Date()
        let cursor = terminalView.getTerminal().getCursorLocation()
        prediction.noteKey(
            .printable("p"),
            cursor: cursor,
            columns: terminalView.getTerminal().cols,
            terminalMode: .plain,
            now: now
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.020) { [weak self] in
            guard let self else { return }
            self.terminalView.feed(byteArray: [UInt8(ascii: "p")][...])
            self.reconcilePrediction(at: now.addingTimeInterval(0.020))
            self.phase = .prediction
            self.runNextPredictionSample()
        }
    }

    private func runNextPredictionSample() {
        guard predictionSamples.count < max(1, options.latencySamples) else {
            report("predictive-overlay-draw", samples: predictionSamples)
            phase = .finished
            NSApp.terminate(nil)
            return
        }
        currentByte = 0x61 + UInt8(predictionSamples.count % 26)
        let event = syntheticKeyEvent(byte: currentByte)
        sampleStart = DispatchTime.now().uptimeNanoseconds
        handlePredictionKey(event)
        terminalView.keyDown(with: event)
    }

    private func handlePredictionKey(_ event: NSEvent) {
        guard let character = event.characters?.first else { return }
        let terminal = terminalView.getTerminal()
        prediction.noteKey(
            .printable(character),
            cursor: terminal.getCursorLocation(),
            columns: terminal.cols,
            terminalMode: terminalMode
        )
        guard prediction.displayGlyphs() == [character] else {
            FileHandle.standardError.write(
                Data(
                    "rai-bench: prediction confidence gate did not open "
                        .appending("pending=\(prediction.pending.count) ")
                        .appending("confirmed=\(prediction.echoConfirmedThisBurst) ")
                        .appending("latency=\(prediction.smoothedConfirmLatency)\n")
                        .utf8
                )
            )
            exit(2)
        }
        overlay.glyphs = [character]
        overlay.isHidden = false
        overlay.needsDisplay = true
        overlay.displayIfNeeded()
    }

    private func predictionOverlayDidDraw() {
        guard phase == .prediction, let start = sampleStart else { return }
        sampleStart = nil
        predictionSamples.append(milliseconds(since: start))
        overlay.isHidden = true
        let byte = currentByte
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.020) { [weak self] in
            guard let self else { return }
            self.terminalView.feed(byteArray: [byte][...])
            self.reconcilePrediction(at: Date())
            // Keep every sample on one cell. A real line wrap ends prediction
            // confidence by design, which would turn this into a safety test.
            self.terminalView.feed(byteArray: [0x08][...])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.001) { [weak self] in
                self?.runNextPredictionSample()
            }
        }
    }

    private func reconcilePrediction(at now: Date) {
        let terminal = terminalView.getTerminal()
        prediction.reconcile(
            cursor: terminal.getCursorLocation(),
            terminalMode: terminalMode,
            readCell: { column, row in
                guard let cell = terminal.getCharData(col: column, row: row) else { return nil }
                let character = cell.getCharacter()
                return character == "\u{0}" ? nil : character
            },
            now: now
        )
    }

    private var terminalMode: PredictiveEchoEngine.TerminalMode {
        let terminal = terminalView.getTerminal()
        return .init(
            alternateScreen: terminal.isCurrentBufferAlternate,
            bracketedPaste: terminal.bracketedPasteMode,
            applicationCursorKeys: terminal.applicationCursor,
            mouseTracking: terminal.mouseMode != .off
        )
    }

    private func syntheticKeyEvent(byte: UInt8) -> NSEvent {
        let character = String(Character(UnicodeScalar(byte)))
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: 0
        ) else {
            fatalError("rai-bench: could not create key event")
        }
        return event
    }

    private func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private func report(_ name: String, samples: [Double]) {
        let sorted = samples.sorted()
        let middle = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
        let p90 = sorted[max(0, Int(ceil(Double(sorted.count) * 0.9)) - 1)]
        print(String(
            format: "latency=%@ samples=%d median=%.3fms p90=%.3fms min=%.3fms max=%.3fms",
            name, sorted.count, median, p90, sorted[0], sorted[sorted.count - 1]
        ))
    }
}

// MARK: - Measurement

/// Process CPU time (user + system). `ps`-style sampling cannot resolve a
/// 20-second window finely enough, and it includes nothing about who spent it.
func processCPUSeconds() -> Double {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    func seconds(_ tv: timeval) -> Double {
        Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
    }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

// MARK: - Corpus

/// Output shaped like an agent TUI: truecolor SGR runs, box drawing, cursor
/// addressing that rewrites a status line in place, and a scrolling body.
/// Deliberately mixes redraw kinds — a pure `cat` would flatter the row cache.
func syntheticCorpus() -> [UInt8] {
    var out = ""
    let words = ["Reading", "Editing", "Searching", "thinking", "tool_use",
                 "Sources/RaiApp/TerminalPaneView.swift", "herdr", "attach", "pane"]
    for i in 0..<400 {
        // A boxed panel, like Claude Code's frames.
        if i % 40 == 0 {
            out += "\u{1b}[38;2;215;119;87m╭" + String(repeating: "─", count: 70) + "╮\u{1b}[0m\n"
            out += "\u{1b}[38;2;215;119;87m│\u{1b}[0m  Claude Code v2.1.220"
            out += String(repeating: " ", count: 47) + "\u{1b}[38;2;215;119;87m│\u{1b}[0m\n"
            out += "\u{1b}[38;2;215;119;87m╰" + String(repeating: "─", count: 70) + "╯\u{1b}[0m\n"
        }
        // A colored, wrapping body line.
        let r = (i &* 37) % 200 + 55
        let g = (i &* 59) % 200 + 55
        let b = (i &* 83) % 200 + 55
        out += "\u{1b}[38;2;\(r);\(g);\(b)m"
        out += "\(i)  " + words[i % words.count] + " "
        out += words[(i &+ 3) % words.count] + " " + words[(i &+ 5) % words.count]
        out += "\u{1b}[0m\n"
        // An in-place status rewrite — the spinner pattern that makes agents
        // expensive: same row, repainted constantly.
        let spinner = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴"][i % 6]
        out += "\u{1b}[s\u{1b}[1G\u{1b}[38;5;244m\(spinner) working… \(i) tokens\u{1b}[0m\u{1b}[u"
    }
    return Array(out.utf8)
}

// MARK: - Harness

@MainActor
final class BenchDelegate: NSObject, NSApplicationDelegate {
    let options: Options
    let corpus: [UInt8]
    private var window: NSWindow!
    private var views: [TerminalView] = []
    private var offsets: [Int] = []
    private var feedTimer: Timer?
    private var bytesFed = 0
    private var measureStartCPU = 0.0
    private var measureStartWall = Date()
    private var measuring = false
    private var metalActive = false

    nonisolated init(options: Options, corpus: [UInt8]) {
        self.options = options
        self.corpus = corpus
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        enableRendererIfNeeded()

        // Warm up: populate the glyph atlas and get the first frames out before
        // the clock starts, so setup cost does not contaminate the delta.
        startFeeding()
        Timer.scheduledTimer(withTimeInterval: options.warmup, repeats: false) { _ in
            MainActor.assumeIsolated { self.beginMeasuring() }
        }
    }

    private func buildWindow() {
        let cols = max(2, Int(ceil(sqrt(Double(options.panes)))))
        let rows = Int(ceil(Double(options.panes) / Double(cols)))
        // Sized from the requested grid, so --cols/--rows actually change what
        // is rendered. A fixed 720x420 made those flags silently inert and any
        // size-based conclusion invalid.
        let probe = TerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 420))
        let cellSize = probe.getOptimalFrameSize()
        let cell = NSSize(
            width: ceil(cellSize.width / 80 * CGFloat(options.cols)) + 4,
            height: ceil(cellSize.height / 25 * CGFloat(options.rows)) + 4)
        let size = NSSize(width: cell.width * CGFloat(cols),
                          height: cell.height * CGFloat(rows))

        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "rai-bench"
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = content

        for index in 0..<options.panes {
            let col = index % cols
            let row = index / cols
            let frame = NSRect(
                x: CGFloat(col) * cell.width,
                y: size.height - CGFloat(row + 1) * cell.height,
                width: cell.width,
                height: cell.height
            )
            let view = TerminalView(frame: frame)
            view.autoresizingMask = []
            content.addSubview(view)
            views.append(view)
            // Stagger start positions so panes are not in lockstep — closer to
            // several agents running independently.
            offsets.append((corpus.count / max(1, options.panes)) * index)
        }

        // On screen: CAMetalLayer needs a real window CAContext to get drawables.
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func enableRendererIfNeeded() {
        guard options.useMetal else { return }
        for view in views {
            do {
                // SwiftTerm suggests aggregated for TUIs that repaint most of
                // the screen each frame — which a scrolling agent pane is.
                if options.aggregated { view.metalBufferingMode = .perFrameAggregated }
                try view.setUseMetal(true)
                if let layer = metalView(in: view)?.layer as? CAMetalLayer {
                    layer.presentsWithTransaction = options.metalPresentsWithTransaction
                    layer.displaySyncEnabled = options.metalDisplaySync
                }
                metalActive = true
            } catch {
                FileHandle.standardError.write(
                    Data("rai-bench: Metal unavailable: \(error)\n".utf8))
                exit(2)
            }
        }
    }

    private func startFeeding() {
        let hz = 60.0
        let perTick = max(1, Int(Double(options.bytesPerSecond) / hz) / max(1, options.panes))
        feedTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / hz, repeats: true) { _ in
            MainActor.assumeIsolated { self.feedTick(perTick) }
        }
    }

    private func feedTick(_ perPane: Int) {
        // Without this an empty corpus makes `chunk` 0, `remaining` never
        // decreases, and the harness hangs before it ever reports.
        guard !corpus.isEmpty else { return }
        for (index, view) in views.enumerated() {
            var start = offsets[index]
            var remaining = perPane
            while remaining > 0 {
                if start >= corpus.count { start = 0 }
                let chunk = min(remaining, corpus.count - start)
                view.feed(byteArray: corpus[start..<(start + chunk)])
                TerminalFeedRepaintPolicy.repaintIfNeeded(
                    byteCount: chunk,
                    isFocused: index == 0,
                    isVisible: true,
                    hasRecentUnpaintedUserInput: false,
                    synchronizedOutputActive: view.getTerminal().synchronizedOutputActive
                ) {
                    view.needsDisplay = true
                    view.displayIfNeeded()
                }
                start += chunk
                remaining -= chunk
                if measuring { bytesFed += chunk }
            }
            offsets[index] = start
        }
    }

    private func beginMeasuring() {
        measuring = true
        bytesFed = 0
        measureStartCPU = processCPUSeconds()
        measureStartWall = Date()
        Timer.scheduledTimer(withTimeInterval: options.seconds, repeats: false) { _ in
            MainActor.assumeIsolated { self.finish() }
        }
    }

    private func finish() {
        let cpu = processCPUSeconds() - measureStartCPU
        let wall = Date().timeIntervalSince(measureStartWall)
        feedTimer?.invalidate()

        let renderer = metalActive
            ? (options.aggregated ? "metal-aggregated" : "metal-perrow")
            : "coregraphics"
        let mb = Double(bytesFed) / 1_048_576
        print(String(
            format: "renderer=%@ panes=%d rate=%dB/s wall=%.2fs cpu=%.2fs cpu%%=%.1f fed=%.1fMB",
            renderer, options.panes, options.bytesPerSecond, wall, cpu,
            cpu / wall * 100, mb))
        NSApp.terminate(nil)
    }
}
