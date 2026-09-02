import Foundation

enum ProcessAncestry {
    /// Reads one process-table snapshot, then follows parent links in memory.
    static func chain(startingAt pid: Int, maximumDepth: Int = 64) -> [Int] {
        guard pid > 0 else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid="]
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return [pid]
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else {
            return [pid]
        }
        var parents: [Int: Int] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2,
                  let child = Int(fields[0]),
                  let parent = Int(fields[1]) else { continue }
            parents[child] = parent
        }
        var result: [Int] = []
        var current = pid
        var seen: Set<Int> = []
        while current > 0, result.count < maximumDepth, seen.insert(current).inserted {
            result.append(current)
            current = parents[current] ?? 0
        }
        return result
    }
}
