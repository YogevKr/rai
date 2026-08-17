import XCTest
@testable import RaiCore

final class MicroHelperWireTests: XCTestCase {
    private func validReport(_ fill: UInt8 = 0xAB) -> [UInt8] {
        var report = [UInt8](repeating: fill, count: MicroFraming.reportSize)
        report[0] = MicroFraming.reportID
        return report
    }

    func testServerMessagesRoundTrip() throws {
        let identity = MicroHelperIdentity(
            vendorID: IOHIDMicroTransport.vendorID,
            productID: IOHIDMicroTransport.productIDs[0],
            manufacturer: "Work Louder",
            product: "Codex Micro",
            transportName: "USB",
            registryEntryID: 0x1000C1CDB
        )
        let messages: [MicroHelperWire.ServerMessage] = [
            .hello(version: MicroHelperWire.version),
            .attached(identity),
            .detached,
            .report(validReport()),
            .error("the helper cannot open the pad: seized"),
        ]
        for message in messages {
            let line = try MicroHelperWire.encode(message)
            XCTAssertEqual(MicroHelperWire.decodeServerMessage(line), message)
            XCTAssertFalse(line.contains(0x0A), "wire lines must not embed newlines")
        }
    }

    func testClientMessageRoundTrip() throws {
        let message = MicroHelperWire.ClientMessage.send(report: validReport(0x01))
        let line = try MicroHelperWire.encode(message)
        XCTAssertEqual(MicroHelperWire.classifyClientLine(line), .message(message))
    }

    func testEncodeRejectsInvalidReports() {
        let shortReport = [UInt8](repeating: 0, count: 10)
        var wrongID = [UInt8](repeating: 0, count: MicroFraming.reportSize)
        wrongID[0] = 0x01
        XCTAssertThrowsError(try MicroHelperWire.encode(.report(shortReport)))
        XCTAssertThrowsError(try MicroHelperWire.encode(.send(report: wrongID)))
    }

    func testDecodeRejectsBadReportPayloads() {
        // Wrong length (63 bytes) and wrong report ID both fail validation.
        let short = Data([MicroFraming.reportID] + [UInt8](repeating: 0, count: 62))
        var wrongID = [UInt8](repeating: 0, count: MicroFraming.reportSize)
        wrongID[0] = 0x05
        for base64 in [short.base64EncodedString(), Data(wrongID).base64EncodedString(), "!!!"] {
            let line = Data(#"{"t":"send","d":"\#(base64)"}"#.utf8)
            XCTAssertEqual(MicroHelperWire.classifyClientLine(line), .malformed)
            let serverLine = Data(#"{"t":"report","d":"\#(base64)"}"#.utf8)
            XCTAssertNil(MicroHelperWire.decodeServerMessage(serverLine))
        }
    }

    func testDecodeIgnoresUnknownTypesAndGarbage() {
        // Unknown types are how future peers extend the protocol; both sides
        // must drop them rather than fail the session.
        XCTAssertNil(MicroHelperWire.decodeServerMessage(Data(#"{"t":"future"}"#.utf8)))
        XCTAssertEqual(
            MicroHelperWire.classifyClientLine(Data(#"{"t":"report"}"#.utf8)),
            .unknownType
        )
        XCTAssertNil(MicroHelperWire.decodeServerMessage(Data("not json".utf8)))
        XCTAssertNil(MicroHelperWire.decodeServerMessage(Data()))
        XCTAssertNil(MicroHelperWire.decodeServerMessage(Data(#"{"t":"hello"}"#.utf8)))
        XCTAssertNil(MicroHelperWire.decodeServerMessage(Data(#"{"t":"error"}"#.utf8)))
    }

    func testAttachedRequiresIdentityFields() {
        let missingNode = Data(#"{"t":"attached","vendorID":1,"productID":2,"transport":"USB"}"#.utf8)
        XCTAssertNil(MicroHelperWire.decodeServerMessage(missingNode))
    }

    func testClassifyClientLineSeparatesUnknownTypesFromGarbage() {
        let valid = try! MicroHelperWire.encode(.send(report: validReport()))
        guard case .message(.send) = MicroHelperWire.classifyClientLine(valid) else {
            return XCTFail("valid send must classify as a message")
        }
        // Unknown envelope type = a newer forward-compatible peer: tolerated.
        XCTAssertEqual(
            MicroHelperWire.classifyClientLine(Data(#"{"t":"ping"}"#.utf8)),
            .unknownType
        )
        // Undecodable JSON and known-type-bad-payload are both strikes.
        XCTAssertEqual(
            MicroHelperWire.classifyClientLine(Data("not json".utf8)),
            .malformed
        )
        XCTAssertEqual(
            MicroHelperWire.classifyClientLine(Data(#"{"t":"send","d":"!!!"}"#.utf8)),
            .malformed
        )
    }

    func testLinkPolicyMatrix() {
        typealias T = MicroHelperTransport
        // A live helper always wins; no helper always means direct.
        XCTAssertEqual(T.chooseLink(probe: .available, directHIDRestricted: true), .helper)
        XCTAssertEqual(T.chooseLink(probe: .available, directHIDRestricted: false), .helper)
        XCTAssertEqual(T.chooseLink(probe: .notInstalled, directHIDRestricted: true), .direct)
        XCTAssertEqual(T.chooseLink(probe: .notInstalled, directHIDRestricted: false), .direct)
        // On 26.6+ the direct link is a silent black hole, so an installed
        // helper is worth waiting for even when it is down or wedged; on
        // older macOS the working direct link must never be blocked by one.
        XCTAssertEqual(
            T.chooseLink(probe: .installedNotRunning, directHIDRestricted: true), .helper
        )
        XCTAssertEqual(
            T.chooseLink(probe: .installedNotRunning, directHIDRestricted: false), .direct
        )
        XCTAssertEqual(
            T.chooseLink(probe: .unreachable("wedged"), directHIDRestricted: true), .helper
        )
        XCTAssertEqual(
            T.chooseLink(probe: .unreachable("wedged"), directHIDRestricted: false),
            .directWithError("wedged")
        )
    }

    func testHelperIdentityMapsToDeviceIdentityForThePanel() {
        let identity = MicroHelperIdentity(
            vendorID: IOHIDMicroTransport.vendorID,
            productID: IOHIDMicroTransport.productIDs[0],
            manufacturer: "Work Louder",
            product: "Codex Micro",
            transportName: "USB",
            registryEntryID: 42
        )
        let device = MicroHelperTransport.deviceIdentity(for: identity)
        XCTAssertEqual(device.transport.displayName, "USB · rai-microd")
        XCTAssertEqual(device.registryEntryID, 42)
        XCTAssertTrue(device.hasVendorCollection)
        XCTAssertTrue(device.hasExpectedReportSizes)
    }
}
