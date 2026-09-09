import Foundation

/// Opt-in fixture configuration permits only named endpoints in an owned disposable SSH server.
public struct LabSSHConfiguration: Decodable, Sendable {
    public let owner: String
    public let configPath: String
    public let wrapperDirectory: String
    public let targets: [String: String]

    public static func load(root: URL?) throws -> Self? {
        guard let root else { return nil }
        let manifest = root.appendingPathComponent(".rai-lab-ssh.json")
        try LabLaunch.requireContainedPath(manifest.path, root: root)
        guard let bytes = try? Data(contentsOf: manifest), bytes.count <= 16_384 else {
            throw LabLaunch.InvalidConfiguration(errorDescription: "Remote lab actions require a disposable SSH fixture.")
        }
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        let marker = root.appendingPathComponent(".rai-lab-owned")
        guard value.owner.hasPrefix("gr.krig.rai.lab."), (try? String(contentsOf: marker, encoding: .utf8)) == value.owner,
              !value.targets.isEmpty, value.targets.count <= 4 else {
            throw LabLaunch.InvalidConfiguration(errorDescription: "The SSH fixture does not belong to this lab.")
        }
        try LabLaunch.requireContainedPath(value.configPath, root: root)
        try LabLaunch.requireContainedPath(value.wrapperDirectory, root: root)
        return value
    }

    public func validate(target: String, socketPath: String? = nil) throws {
        guard let prefix = targets[target], prefix.hasPrefix("/"), !prefix.contains("..") else {
            throw LabLaunch.InvalidConfiguration(errorDescription: "This SSH target is outside the disposable lab.")
        }
        if let socketPath {
            guard socketPath.hasPrefix(prefix + "/"), !socketPath.split(separator: "/").contains("..") else {
                throw LabLaunch.InvalidConfiguration(errorDescription: "The remote socket is outside the disposable lab.")
            }
        }
    }
}
