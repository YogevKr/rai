import CryptoKit
import Foundation
import RaiCore

/// Downloads and verifies updates off the main actor. No shell text includes release data.
struct AppUpdateService: Sendable {
    let applicationURL: URL
    var session: URLSession = .shared

    func latestRelease() async throws -> AppRelease {
        var request = URLRequest(url: AppRelease.latestURL)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Rai", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppUpdateError.downloadFailed }
        guard let release = try AppRelease.decode(data) else { throw AppUpdateError.invalidRelease }
        return release
    }

    func prepare(_ release: AppRelease) async throws -> AppUpdateInstallation {
        let manager = FileManager.default
        let target = applicationURL.standardizedFileURL
        let parent = target.deletingLastPathComponent()
        guard target.pathExtension == "app", target == target.resolvingSymlinksInPath(),
              manager.isWritableFile(atPath: target.path), manager.isWritableFile(atPath: parent.path),
              Bundle(url: target)?.bundleIdentifier == AppUpdateVerification.bundleIdentifier,
              manager.isExecutableFile(atPath: target.appendingPathComponent("Contents/MacOS/rai-updater").path)
        else { throw AppUpdateError.cannotInstall }
        let staging = parent.appendingPathComponent(".rai-update-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var prepared = false
        defer { if !prepared { try? manager.removeItem(at: staging) } }

        var request = URLRequest(url: release.downloadURL)
        request.timeoutInterval = 120
        let (download, response) = try await session.download(for: request)
        defer { try? manager.removeItem(at: download) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppUpdateError.downloadFailed }
        let archive = staging.appendingPathComponent("update.zip")
        try manager.moveItem(at: download, to: archive)
        let installation = AppUpdateInstallation(
            parentPID: ProcessInfo.processInfo.processIdentifier, target: target,
            staging: staging, version: release.version.description
        )
        try await Task.detached(priority: .utility) {
            try Self.verifyArchive(archive, release: release)
            try Self.validateArchiveEntries(archive)
            _ = try Self.run("/usr/bin/ditto", ["-x", "-k", archive.path, staging.path])
            try installation.validatePaths()
            try AppUpdateVerification.verifyApplication(at: installation.candidate, version: installation.version)
            // Gatekeeper also verifies notarization. Preserve quarantine and the stapled ticket.
            _ = try Self.run("/usr/sbin/spctl", ["--assess", "--type", "execute", installation.candidate.path])
            try manager.copyItem(
                at: target.appendingPathComponent("Contents/MacOS/rai-updater"),
                to: staging.appendingPathComponent("rai-updater")
            )
            let data = try JSONEncoder().encode(installation)
            try data.write(to: staging.appendingPathComponent("installation.json"), options: .atomic)
            try manager.removeItem(at: archive)
        }.value
        prepared = true
        return installation
    }

    /// Wait for the helper's ready marker before requesting normal app shutdown.
    func launchInstaller(_ installation: AppUpdateInstallation) async throws {
        let process = Process()
        process.executableURL = installation.staging.appendingPathComponent("rai-updater")
        process.arguments = [installation.staging.appendingPathComponent("installation.json").path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.currentDirectoryURL = installation.staging
        try process.run()
        let ready = installation.staging.appendingPathComponent("ready")
        for _ in 0..<300 {
            if FileManager.default.fileExists(atPath: ready.path) { return }
            guard process.isRunning else { throw AppUpdateError.cannotInstall }
            try await Task.sleep(for: .milliseconds(100))
        }
        // This process belongs to this update. Rai and Herdr are still running.
        if process.isRunning { process.terminate() }
        throw AppUpdateError.cannotInstall
    }

    static func verifyArchive(_ archive: URL, release: AppRelease) throws {
        let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size == Int(release.size) else { throw AppUpdateError.invalidArchive }
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        var hash = SHA256()
        while let block = try handle.read(upToCount: 1024 * 1024), !block.isEmpty { hash.update(data: block) }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == release.sha256 else { throw AppUpdateError.invalidArchive }
    }

    static func validateArchiveEntries(_ archive: URL) throws {
        let names = try run("/usr/bin/zipinfo", ["-1", archive.path])
        guard !names.isEmpty else { throw AppUpdateError.invalidArchive }
        for name in names.split(separator: "\n", omittingEmptySubsequences: false) where !name.isEmpty {
            let parts = name.split(separator: "/")
            guard !name.hasPrefix("/"), !parts.contains(".."), !parts.contains("."),
                  parts.first == "Rai.app" || parts.first == "__MACOSX",
                  !name.contains("\\") else { throw AppUpdateError.invalidArchive }
        }
        // Rai's current bundle has no symlinks. Reject them before extraction,
        // so an archive cannot redirect a later entry outside this directory.
        let listing = try run("/usr/bin/zipinfo", ["-l", archive.path])
        guard !listing.split(separator: "\n").contains(where: { $0.hasPrefix("l") })
        else { throw AppUpdateError.invalidArchive }
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AppUpdateError.invalidArchive }
        return String(decoding: data, as: UTF8.self)
    }
}
