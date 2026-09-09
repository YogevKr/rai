import Foundation

/// Retains private-protocol clients when an installation update leaves old servers running.
public struct HerdrClientArchive: Sendable {
    public let directory: URL

    public init(directory: URL = AppDataPaths.current.applicationSupport.appendingPathComponent("herdr-clients")) {
        self.directory = directory
    }

    public func executable(for protocolVersion: Int) -> URL? {
        let url = destination(protocolVersion)
        return ExecutableFile.isAvailable(at: url.path) ? url : nil
    }

    public func retain(
        source: URL,
        protocolVersion: Int,
        inspect: (URL) async throws -> Int
    ) async throws -> URL {
        if let existing = executable(for: protocolVersion) {
            try await validate(existing, protocolVersion: protocolVersion, inspect: inspect)
            return existing
        }
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent("staging-\(UUID().uuidString)")
        try files.copyItem(at: source.resolvingSymlinksInPath(), to: temporary)
        defer { try? files.removeItem(at: temporary) }
        try await validate(temporary, protocolVersion: protocolVersion, inspect: inspect)
        try Task.checkCancellation()
        let target = destination(protocolVersion)
        // Never replace an existing archived executable used by another view.
        try files.moveItem(at: temporary, to: target)
        return target
    }

    private func destination(_ protocolVersion: Int) -> URL {
        directory.appendingPathComponent("herdr-protocol-\(protocolVersion)")
    }

    private func validate(_ executable: URL, protocolVersion: Int, inspect: (URL) async throws -> Int) async throws {
        guard ExecutableFile.isAvailable(at: executable.path),
              try await inspect(executable) == protocolVersion else {
            throw HerdrClientError.remote(code: "client_protocol_mismatch", message: "Rai could not retain a compatible Herdr client. The installation was not updated.")
        }
    }
}
