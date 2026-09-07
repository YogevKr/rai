#if os(macOS)
import Foundation
import Security

public enum AppUpdateError: LocalizedError, Equatable {
    case invalidRelease, downloadFailed, invalidArchive, invalidApplication, invalidSignature
    case cannotInstall, applicationStillRunning, installationFailed, rollbackFailed, restartFailed

    public var errorDescription: String? {
        switch self {
        case .invalidRelease: return "The release does not contain a supported Rai update."
        case .downloadFailed: return "Rai could not download the update. Check your connection and try again."
        case .invalidArchive: return "The update download did not pass verification. Please try again."
        case .invalidApplication: return "The download does not contain the expected Rai version."
        case .invalidSignature: return "The update did not pass the Rai signature check."
        case .cannotInstall: return "Move Rai to a writable Applications folder, then try again."
        case .applicationStillRunning: return "Rai did not close. The installed version has not changed."
        case .installationFailed: return "Rai could not install the update. The previous version has been restored."
        case .rollbackFailed: return "Rai could not restore the previous version. It remains in the update backup folder."
        case .restartFailed: return "Rai installed the update but could not restart. Open Rai from Applications."
        }
    }
}

/// The same check runs before quitting and again in the independent installer.
public enum AppUpdateVerification {
    public static let bundleIdentifier = "gr.krig.rai"
    // The public Developer ID team on Rai's notarized releases. Local development
    // signatures must never authorize a different publisher's update.
    public static let signingRequirement = """
    identifier "gr.krig.rai" and anchor apple generic \
    and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
    and certificate leaf[field.1.2.840.113635.100.6.1.13] exists \
    and certificate leaf[subject.OU] = "T2XB37WVYD"
    """

    public static func verifyApplication(at url: URL, version: String) throws {
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil)
            as? [String: Any]
        guard info?["CFBundleIdentifier"] as? String == bundleIdentifier,
              info?["CFBundleShortVersionString"] as? String == version,
              info?["CFBundleExecutable"] as? String == "rai",
              FileManager.default.isExecutableFile(atPath: url.appendingPathComponent("Contents/MacOS/rai").path)
        else { throw AppUpdateError.invalidApplication }
        if let minimum = info?["LSMinimumSystemVersion"] as? String {
            let parts = minimum.split(separator: ".").compactMap { Int($0) }
            guard !parts.isEmpty, parts.count <= 3 else { throw AppUpdateError.invalidApplication }
            let os = OperatingSystemVersion(
                majorVersion: parts[0], minorVersion: parts.count > 1 ? parts[1] : 0,
                patchVersion: parts.count > 2 ? parts[2] : 0
            )
            guard ProcessInfo.processInfo.isOperatingSystemAtLeast(os) else { throw AppUpdateError.invalidApplication }
        }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(signingRequirement as CFString, [], &requirement) == errSecSuccess,
              let code, let requirement,
              SecStaticCodeCheckValidity(
                code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate),
                requirement
              ) == errSecSuccess
        else { throw AppUpdateError.invalidSignature }
    }
}

/// This manifest lives in an owner-only staging directory beside the installed app.
public struct AppUpdateInstallation: Codable, Sendable {
    public let parentPID: Int32
    public let target: URL
    public let staging: URL
    public let version: String

    public init(parentPID: Int32, target: URL, staging: URL, version: String) {
        self.parentPID = parentPID
        self.target = target
        self.staging = staging
        self.version = version
    }

    public var candidate: URL { staging.appendingPathComponent("Rai.app") }
    public var backup: URL { staging.appendingPathComponent("Previous-Rai.app") }

    public func validatePaths() throws {
        let manager = FileManager.default
        let parent = target.deletingLastPathComponent().standardizedFileURL
        guard parentPID > 1, target.pathExtension == "app",
              target.standardizedFileURL == target.resolvingSymlinksInPath(),
              staging.standardizedFileURL == staging.resolvingSymlinksInPath(),
              candidate.standardizedFileURL == candidate.resolvingSymlinksInPath(),
              staging.deletingLastPathComponent().standardizedFileURL == parent,
              staging.lastPathComponent.hasPrefix(".rai-update-"),
              manager.isWritableFile(atPath: parent.path),
              manager.isWritableFile(atPath: target.path),
              !manager.fileExists(atPath: backup.path)
        else { throw AppUpdateError.cannotInstall }
    }

    /// Move on the same volume. If the second move fails, restore the old bundle.
    /// Keep the backup after success, so a failed launch remains recoverable.
    public func replaceApplication(
        move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    ) throws {
        try validatePaths()
        try move(target, backup)
        do {
            try move(candidate, target)
        } catch {
            do { try move(backup, target) }
            catch { throw AppUpdateError.rollbackFailed }
            throw AppUpdateError.installationFailed
        }
    }
}

extension AppUpdateInstallation {
    /// Update folders whose installer wrote `result.txt`: the new version is in
    /// place and `Previous-Rai.app` only serves a rollback. Each one is a second
    /// bundle registered under Rai's identifier, so LaunchServices, Finder, and
    /// TCC prompts start naming the stale copy instead of the installed app.
    /// Callers prune once the installed app has proven it launches.
    public static func completedStagingDirectories(
        besideApplication target: URL, manager: FileManager = .default
    ) -> [URL] {
        let target = target.standardizedFileURL
        let parent = target.deletingLastPathComponent()
        guard let siblings = try? manager.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else { return [] }
        return siblings.filter { staging in
            guard staging.lastPathComponent.hasPrefix(".rai-update-"),
                  let values = try? staging.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  manager.fileExists(atPath: staging.appendingPathComponent("result.txt").path),
                  let data = try? Data(contentsOf: staging.appendingPathComponent("installation.json")),
                  let installation = try? JSONDecoder().decode(AppUpdateInstallation.self, from: data)
            else { return false }
            // Compare paths: a directory URL may carry a trailing slash on one side only.
            return installation.target.standardizedFileURL.path == target.path
                && installation.staging.standardizedFileURL.path == staging.standardizedFileURL.path
        }
        .sorted { $0.path < $1.path }
    }

    /// Removes every completed update folder beside the app. Returns what it removed.
    @discardableResult
    public static func pruneCompletedStaging(
        besideApplication target: URL, manager: FileManager = .default
    ) -> [URL] {
        completedStagingDirectories(besideApplication: target, manager: manager).filter { staging in
            (try? manager.removeItem(at: staging)) != nil
        }
    }
}
#endif
