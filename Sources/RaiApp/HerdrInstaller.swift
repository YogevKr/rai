import CryptoKit
import Foundation
import RaiCore

/// Installs the checksum-verified stable release without changing shell files or existing binaries.
struct HerdrInstaller: Sendable {
    struct Release: Decodable {
        let version: String
        let assets: [String: URL]
        let sha256: [String: String]

        func asset(for platform: String) throws -> (URL, String) {
            guard let url = assets[platform], url.scheme == "https", url.host == "github.com",
                  url.path.hasPrefix("/herdrdev/herdr/releases/download/"),
                  let digest = sha256[platform], digest.count == 64,
                  digest.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
                throw Failure("The Herdr release has no verified download for this Mac.")
            }
            return (url, digest.lowercased())
        }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func destination(environment: [String: String], homeDirectory: String) throws -> URL {
        let path = environment["HERDR_BIN_PATH"].flatMap { $0.isEmpty ? nil : $0 }
            ?? homeDirectory + "/.local/bin/herdr"
        guard path.hasPrefix("/") else { throw Failure("HERDR_BIN_PATH must be an absolute path.") }
        let root = environment["RAI_DATA_ROOT"].map { URL(fileURLWithPath: $0) }
        try LabLaunch.requireContainedPath(path, root: root)
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    func install(to destination: URL, labRoot: URL? = nil) async throws {
        var request = URLRequest(url: URL(string: "https://herdr.dev/latest.json")!)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 2_000_000 else {
            throw Failure("Rai could not get the Herdr release. Check your connection and try again.")
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        #if arch(arm64)
        let platform = "macos-aarch64"
        #else
        let platform = "macos-x86_64"
        #endif
        let (url, checksum) = try release.asset(for: platform)
        request = URLRequest(url: url)
        request.timeoutInterval = 120
        let (download, downloadResponse) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: download) }
        guard (downloadResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure("The Herdr download failed. Check your connection and try again.")
        }
        try Task.checkCancellation()
        try Self.install(download: download, checksum: checksum, to: destination, labRoot: labRoot)
    }

    static func install(download: URL, checksum: String, to destination: URL, labRoot: URL?) throws {
        let manager = FileManager.default
        let size = try download.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size < 100_000_000 else { throw Failure("The Herdr download has an invalid size.") }
        let data = try Data(contentsOf: download, options: .mappedIfSafe)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == checksum else { throw Failure("The Herdr download failed its checksum check. Try again.") }
        try LabLaunch.requireContainedPath(destination.path, root: labRoot)
        let parent = destination.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".herdr-install-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: staging) }
        try manager.copyItem(at: download, to: staging)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
        try LabLaunch.requireContainedPath(destination.path, root: labRoot)
        // A hard link publishes a complete executable and refuses any existing destination.
        try manager.linkItem(at: staging, to: destination)
    }
}
