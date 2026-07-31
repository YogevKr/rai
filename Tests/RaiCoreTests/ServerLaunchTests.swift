import XCTest
@testable import RaiCore

final class ServerLaunchTests: XCTestCase {
    private func session(
        name: String,
        isDefault: Bool = false,
        isRunning: Bool = false,
        socketPath: String
    ) -> HerdrSession {
        HerdrSession(
            name: name,
            isDefault: isDefault,
            isRunning: isRunning,
            sessionDirectory: (socketPath as NSString).deletingLastPathComponent,
            socketPath: socketPath
        )
    }

    func testDefaultSessionStartsWithoutSessionFlag() {
        let arguments = HerdrServerLaunch.serverArguments(
            for: session(
                name: "default",
                isDefault: true,
                socketPath: "/Users/x/.config/herdr/herdr.sock"
            )
        )
        XCTAssertEqual(arguments, ["server"])
    }

    func testNamedSessionStartsWithSessionFlag() {
        let arguments = HerdrServerLaunch.serverArguments(
            for: session(
                name: "lab",
                socketPath: "/Users/x/.config/herdr/sessions/lab/herdr.sock"
            )
        )
        XCTAssertEqual(arguments, ["--session", "lab", "server"])
    }

    func testAutostartsTheStoppedHerdRaiPointsAt() {
        let target = HerdrServerLaunch.autostartTarget(
            socketPath: "/Users/x/.config/herdr/herdr.sock",
            sessions: [
                session(
                    name: "default",
                    isDefault: true,
                    isRunning: false,
                    socketPath: "/Users/x/.config/herdr/herdr.sock"
                ),
                session(
                    name: "lab",
                    isRunning: true,
                    socketPath: "/Users/x/.config/herdr/sessions/lab/herdr.sock"
                ),
            ]
        )
        XCTAssertEqual(target?.name, "default")
    }

    func testNoAutostartWhenTheServerAlreadyRuns() {
        XCTAssertNil(
            HerdrServerLaunch.autostartTarget(
                socketPath: "/Users/x/.config/herdr/herdr.sock",
                sessions: [
                    session(
                        name: "default",
                        isDefault: true,
                        isRunning: true,
                        socketPath: "/Users/x/.config/herdr/herdr.sock"
                    ),
                ]
            )
        )
    }

    /// A socket herdr does not list — a custom HERDR_SOCKET_PATH, or the local
    /// end of an SSH tunnel — gives rai no way to know what to start.
    func testNoAutostartForAnUnknownSocket() {
        XCTAssertNil(
            HerdrServerLaunch.autostartTarget(
                socketPath: "/tmp/rai-remote-4711/herdr.sock",
                sessions: [
                    session(
                        name: "default",
                        isDefault: true,
                        isRunning: true,
                        socketPath: "/Users/x/.config/herdr/herdr.sock"
                    ),
                ]
            )
        )
    }

    func testMatchesSocketsThatDifferOnlyInPathForm() {
        let target = HerdrServerLaunch.autostartTarget(
            socketPath: "/Users/x/.config/herdr/sessions/lab/../lab/herdr.sock",
            sessions: [
                session(
                    name: "lab",
                    socketPath: "/Users/x/.config/herdr/sessions/lab/herdr.sock"
                ),
            ]
        )
        XCTAssertEqual(target?.name, "lab")
    }
}
