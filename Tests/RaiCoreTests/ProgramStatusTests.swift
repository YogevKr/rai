import XCTest
@testable import RaiCore

final class ProgramStatusTests: XCTestCase {
    func testDecodesProgramStatusAndUnknownFutureValues() throws {
        let data = #"{"records":[{"id":"","state":"blocked","kind":"permission","progress":25,"app":"claude","title":"Permission","message":"Allow access"},{"id":"tool","state":"future_state"}]}"#.data(using: .utf8)!
        let info = try JSONDecoder().decode(ProgramStatusInfo.self, from: data)

        XCTAssertEqual(info.records[0].state, .blocked)
        XCTAssertEqual(info.records[0].kind, .permission)
        XCTAssertEqual(info.records[0].message, "Allow access")
        XCTAssertEqual(info.records[1].state, .unknown)
    }

    func testProgramMessagePrecedesBeaconFallback() {
        let info = ProgramStatusInfo(records: [
            ProgramStatusRecord(
                id: "",
                state: .blocked,
                kind: .permission,
                progress: nil,
                app: "claude",
                title: "Permission",
                message: "Allow access"
            )
        ])

        XCTAssertEqual(
            AgentNotificationBody.compose(
                status: .blocked,
                beacon: nil,
                programStatus: info
            ),
            "Allow access"
        )
    }
}
