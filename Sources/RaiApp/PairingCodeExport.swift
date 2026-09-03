import Foundation

/// Test affordance: when `RAI_PAIRING_CODE_FILE` names a path, the bridge
/// mirrors its current pairing code there so an end-to-end harness can pair
/// a simulator without driving the Settings window. The file is owner-only
/// and holds one line: the code, or nothing while no code is valid. Never
/// set in normal use, and the code is short-lived either way.
enum PairingCodeExport {
    static let environmentKey = "RAI_PAIRING_CODE_FILE"

    static var configuredURL: URL? {
        guard let path = ProcessInfo.processInfo.environment[environmentKey],
              !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func write(code: String?, to url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let contents = (code ?? "") + "\n"
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
