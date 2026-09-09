import Foundation
import XCTest
@testable import RaiCore

final class LabSSHConfigurationTests: XCTestCase {
    func testRemoteAccessRequiresOwnedFixtureAndAnExactTargetAndSocket() throws {
        XCTAssertNil(try LabSSHConfiguration.load(root: nil))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try LabSSHConfiguration.load(root: root))
        let owner = "gr.krig.rai.lab.fixture"
        try owner.write(to: root.appendingPathComponent(".rai-lab-owned"), atomically: true, encoding: .utf8)
        var manifest: [String: Any] = ["owner": owner, "configPath": root.appendingPathComponent("config").path,
            "wrapperDirectory": root.appendingPathComponent("bin").path, "targets": ["lab-one": "/home/labone/.config/herdr"]]
        let path = root.appendingPathComponent(".rai-lab-ssh.json")
        try JSONSerialization.data(withJSONObject: manifest).write(to: path)
        let config = try XCTUnwrap(LabSSHConfiguration.load(root: root))
        XCTAssertNoThrow(try config.validate(target: "lab-one", socketPath: "/home/labone/.config/herdr/herdr.sock"))
        XCTAssertThrowsError(try config.validate(target: "production"))
        XCTAssertThrowsError(try config.validate(target: "lab-one", socketPath: "/home/labtwo/.config/herdr/herdr.sock"))
        XCTAssertThrowsError(try config.validate(target: "lab-one", socketPath: "/home/labone/.config/herdr/../other.sock"))
        manifest["owner"] = "gr.krig.rai.lab.other"
        try JSONSerialization.data(withJSONObject: manifest).write(to: path)
        XCTAssertThrowsError(try LabSSHConfiguration.load(root: root))
    }
}
