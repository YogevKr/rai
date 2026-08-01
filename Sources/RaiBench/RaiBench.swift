import AppKit
import Foundation
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
    var cols = 100
    var rows = 32

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
            case "--renderer": o.useMetal = (value() ?? "metal") != "cg"
            case "--seconds": o.seconds = Double(value() ?? "") ?? o.seconds
            case "--warmup": o.warmup = Double(value() ?? "") ?? o.warmup
            case "--rate": o.bytesPerSecond = Int(value() ?? "") ?? o.bytesPerSecond
            case "--corpus": o.corpusPath = value()
            case "--cols": o.cols = Int(value() ?? "") ?? o.cols
            case "--rows": o.rows = Int(value() ?? "") ?? o.rows
            case "--help", "-h":
                print("""
                rai-bench — CoreGraphics vs Metal pane rendering

                  --panes N        panes in the grid (default 4)
                  --renderer R     metal | cg (default metal)
                  --seconds S      measurement window (default 20)
                  --warmup S       excluded warmup before measuring (default 3)
                  --rate B         bytes/second fed across all panes (default 200000)
                  --corpus PATH    replay these bytes (default: synthetic TUI-like output)
                  --cols / --rows  per-pane grid size (default 100x32)
                """)
                exit(0)
            default: break
            }
            i += 1
        }
        return o
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
        let cell = NSSize(width: 720, height: 420)
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
                try view.setUseMetal(true)
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
        for (index, view) in views.enumerated() {
            var start = offsets[index]
            var remaining = perPane
            while remaining > 0 {
                if start >= corpus.count { start = 0 }
                let chunk = min(remaining, corpus.count - start)
                view.feed(byteArray: corpus[start..<(start + chunk)])
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

        let renderer = metalActive ? "metal" : "coregraphics"
        let mb = Double(bytesFed) / 1_048_576
        print(String(
            format: "renderer=%@ panes=%d rate=%dB/s wall=%.2fs cpu=%.2fs cpu%%=%.1f fed=%.1fMB",
            renderer, options.panes, options.bytesPerSecond, wall, cpu,
            cpu / wall * 100, mb))
        NSApp.terminate(nil)
    }
}

// MARK: - Entry

let options = Options.parse(Array(CommandLine.arguments.dropFirst()))
let corpus: [UInt8]
if let path = options.corpusPath {
    guard let data = FileManager.default.contents(atPath: path) else {
        FileHandle.standardError.write(Data("rai-bench: cannot read \(path)\n".utf8))
        exit(1)
    }
    corpus = [UInt8](data)
} else {
    corpus = syntheticCorpus()
}

let app = NSApplication.shared
let delegate = BenchDelegate(options: options, corpus: corpus)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
