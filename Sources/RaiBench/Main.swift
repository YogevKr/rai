import AppKit
import Foundation

// A separate file on purpose: with a single source file SwiftPM compiles the
// executable as top-level script code, but the universal release build passes
// -parse-as-library, which rejects that. Two files force library parsing in
// both build systems, with @main as the one entry point.
@main
enum RaiBenchMain {
    @MainActor
    static func main() {
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
        let delegate: NSApplicationDelegate = options.latency
            ? LatencyBenchDelegate(options: options)
            : BenchDelegate(options: options, corpus: corpus)
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
