import Foundation
import RaiCore

/// Finds git checkouts under the configured project roots, on whichever host
/// the herd runs on.
///
/// Local herds are walked with `FileManager`; remote herds are scanned over the
/// same ssh target the socket tunnel uses. Scanning the *daemon's* filesystem is
/// the point: `workspace create --cwd` is interpreted by the daemon, so a path
/// discovered anywhere else would be meaningless to it.
enum RepoScanner {
    static func scan(
        roots: [String],
        depth: Int,
        remoteTarget: String?
    ) async -> [DiscoveredRepo] {
        let cleaned = roots
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return [] }

        if let remoteTarget {
            return await scanRemote(target: remoteTarget, roots: cleaned, depth: depth)
        }
        return await scanLocal(roots: cleaned, depth: depth)
    }

    // MARK: - Local

    private static func scanLocal(roots: [String], depth: Int) async -> [DiscoveredRepo] {
        await Task.detached(priority: .utility) {
            walk(roots: roots, depth: depth)
        }.value
    }

    /// Breadth-first walk that stops at the first checkout on each branch. Not
    /// descending into a repo keeps a monorepo's vendored submodules out of the
    /// palette and bounds the work on deep trees.
    private static func walk(roots: [String], depth: Int) -> [DiscoveredRepo] {
        let manager = FileManager.default
        let levels = min(max(depth, 1), RepoDiscoveryPlanner.maxDepth)
        var repos: [DiscoveredRepo] = []
        var seen = Set<String>()

        for root in roots {
            var frontier = [NSString(string: root).expandingTildeInPath]
            for _ in 0..<levels {
                var next: [String] = []
                for directory in frontier {
                    guard let names = try? manager.contentsOfDirectory(atPath: directory) else {
                        continue
                    }
                    for name in names where !name.hasPrefix(".") {
                        let child = (directory as NSString).appendingPathComponent(name)
                        var isDirectory: ObjCBool = false
                        guard manager.fileExists(atPath: child, isDirectory: &isDirectory),
                              isDirectory.boolValue else { continue }
                        // `.git` is a directory in a clone and a file in a
                        // linked worktree; both mean "this is a checkout".
                        let marker = (child as NSString).appendingPathComponent(".git")
                        if manager.fileExists(atPath: marker) {
                            guard seen.insert(RepoDiscoveryPlanner.normalized(child)).inserted else {
                                continue
                            }
                            repos.append(
                                DiscoveredRepo(
                                    path: child,
                                    name: RepoDiscoveryPlanner.name(for: child)
                                )
                            )
                        } else {
                            next.append(child)
                        }
                    }
                }
                frontier = next
                if frontier.isEmpty { break }
            }
        }

        return RepoDiscoveryPlanner.candidates(repos: repos, openPaths: [])
    }

    // MARK: - Remote

    private static func scanRemote(
        target: String,
        roots: [String],
        depth: Int
    ) async -> [DiscoveredRepo] {
        let script = RepoDiscoveryPlanner.scanScript(roots: roots, depth: depth)
        guard !script.isEmpty else { return [] }
        guard let output = await runProcess(
            executable: "/usr/bin/ssh",
            arguments: [
                // The tunnel already proved this target reachable, so refuse
                // interactive prompts rather than hang the palette on one.
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=10",
                target,
                script,
            ]
        ) else { return [] }
        return RepoDiscoveryPlanner.parse(scanOutput: output)
    }

    private static func runProcess(
        executable: String,
        arguments: [String]
    ) async -> String? {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return nil
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        }.value
    }
}
