import CorralCore
import XCTest

final class SessionListTests: XCTestCase {
    func testParsesSessionList() throws {
        let json = """
        {
          "sessions": [
            {
              "name": "default",
              "default": true,
              "running": true,
              "session_dir": "/Users/test/.config/herdr",
              "socket_path": "/Users/test/.config/herdr/herdr.sock"
            },
            {
              "name": "review",
              "default": false,
              "running": false,
              "session_dir": "/Users/test/.config/herdr/sessions/review",
              "socket_path": "/Users/test/.config/herdr/sessions/review/herdr.sock"
            }
          ]
        }
        """

        let sessions = try SessionListParser.parse(json)

        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].name, "default")
        XCTAssertTrue(sessions[0].isDefault)
        XCTAssertTrue(sessions[0].isRunning)
        XCTAssertEqual(sessions[1].name, "review")
        XCTAssertFalse(sessions[1].isDefault)
        XCTAssertFalse(sessions[1].isRunning)
        XCTAssertEqual(
            sessions[1].socketPath,
            "/Users/test/.config/herdr/sessions/review/herdr.sock"
        )
    }

    func testRejectsMissingRequiredSessionFields() {
        let json = """
        {"sessions":[{"name":"default","default":true,"running":true}]}
        """

        XCTAssertThrowsError(try SessionListParser.parse(json))
    }
}
