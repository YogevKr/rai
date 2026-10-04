import Foundation

/// Stable Rai releases use three numeric components. Compare numbers, not tags.
public struct AppReleaseVersion: Comparable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(_ value: String) {
        let text = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2])
        else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

public struct AppRelease: Equatable, Sendable {
    public let version: AppReleaseVersion
    public let downloadURL: URL
    public let size: Int64
    public let sha256: String

    public static let latestURL = URL(string: "https://api.github.com/repos/YogevKr/rai/releases/latest")!
    public static let latestFeedURL = URL(string: "https://github.com/YogevKr/rai/releases.atom")!
    public static let maximumArchiveBytes: Int64 = 512 * 1024 * 1024

    public static func archiveURL(for version: AppReleaseVersion) -> URL {
        URL(string: "https://github.com/YogevKr/rai/releases/download/v\(version.description)/Rai-\(version.description)-macos.zip")!
    }

    public static func manifestURL(for version: AppReleaseVersion) -> URL {
        URL(string: "https://github.com/YogevKr/rai/releases/download/v\(version.description)/Rai-\(version.description)-macos.json")!
    }

    public static func decode(_ data: Data) throws -> AppRelease? {
        let release = try JSONDecoder().decode(FeedRelease.self, from: data)
        guard !release.draft, !release.prerelease,
              let version = AppReleaseVersion(release.tag_name),
              release.tag_name == "v\(version.description)" else { return nil }
        let name = "Rai-\(version.description)-macos.zip"
        let expectedURL = archiveURL(for: version).absoluteString
        guard let asset = release.assets.first(where: { $0.name == name && $0.state == "uploaded" }),
              asset.browser_download_url.absoluteString == expectedURL,
              asset.size > 0, asset.size <= maximumArchiveBytes,
              let digest = asset.digest, digest.hasPrefix("sha256:") else { return nil }
        let hash = String(digest.dropFirst(7))
        guard hash.count == 64, hash.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return AppRelease(version: version, downloadURL: asset.browser_download_url, size: asset.size, sha256: hash)
    }

    public static func decodeManifest(_ data: Data) throws -> AppRelease? {
        struct Manifest: Decodable {
            let version: String
            let size: Int64
            let sha256: String
            let prerelease: Bool
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard let version = AppReleaseVersion(manifest.version),
              !manifest.prerelease,
              manifest.size > 0, manifest.size <= maximumArchiveBytes,
              manifest.sha256.count == 64,
              manifest.sha256.allSatisfy({ "0123456789abcdef".contains($0) })
        else { return nil }
        return AppRelease(
            version: version,
            downloadURL: archiveURL(for: version),
            size: manifest.size,
            sha256: manifest.sha256
        )
    }

    public func shouldOffer(currentVersion: String, skippedVersion: String?, manual: Bool) -> Bool {
        guard let current = AppReleaseVersion(currentVersion), version > current else { return false }
        return manual || skippedVersion != version.description
    }

    private struct FeedRelease: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    private struct Asset: Decodable {
        let name: String
        let state: String
        let browser_download_url: URL
        let size: Int64
        let digest: String?
    }
}
