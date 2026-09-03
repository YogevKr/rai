import Foundation
import XCTest
@testable import RaiApp

final class PairingCodeExportTests: XCTestCase {
    func testWritesOwnerOnlyFileWithOneLine() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rai-pairing-export-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("code.txt")

        try PairingCodeExport.write(code: "ABCD2345", to: url)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "ABCD2345\n")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)

        try PairingCodeExport.write(code: nil, to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "\n")
        try? FileManager.default.removeItem(at: directory)
    }

    func testUnsetEnvironmentMeansNoExport() {
        // The harness variable is never set inside the test process.
        XCTAssertNil(PairingCodeExport.configuredURL)
    }
}
