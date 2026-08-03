import XCTest

@testable import RaiApp

/// herdr ≥ 0.7.5 serves terminal attach on a `-client.sock` sibling of the RPC
/// socket, and the CLI derives that name from `HERDR_SOCKET_PATH`. (Regression:
/// the tunnel forwarded only the RPC socket, so every remote pane's
/// `herdr terminal attach` died with "No such file or directory" on the derived
/// `/tmp/rai-…-client.sock` path — connect and workspace RPCs still worked,
/// which masked the breakage until a pane tried to render.)
@MainActor
final class RemoteConnectionTests: XCTestCase {
    func testClientSocketPathMatchesHerdrDerivation() {
        XCTAssertEqual(
            RemoteConnection.clientSocketPath(
                for: "/Users/yogev/.config/herdr/herdr.sock"
            ),
            "/Users/yogev/.config/herdr/herdr-client.sock"
        )
        XCTAssertEqual(
            RemoteConnection.clientSocketPath(for: "/tmp/rai-93193FAB-64C.sock"),
            "/tmp/rai-93193FAB-64C-client.sock"
        )
    }

    func testTunnelForwardsBothSockets() {
        let connection = RemoteConnection(
            target: "user@host",
            sessionName: "default",
            remoteSocketPath: "/home/user/.config/herdr/herdr.sock"
        )
        let arguments = connection.tunnelArguments

        var forwards: [String] = []
        for (index, argument) in arguments.enumerated() where argument == "-L" {
            forwards.append(arguments[index + 1])
        }
        XCTAssertEqual(
            forwards,
            [
                "\(connection.localSocketPath):/home/user/.config/herdr/herdr.sock",
                "\(connection.localClientSocketPath):/home/user/.config/herdr/herdr-client.sock",
            ]
        )
        XCTAssertEqual(arguments.last, "user@host")
    }

    func testLocalClientSocketPairsWithLocalSocket() {
        let connection = RemoteConnection(
            target: "user@host",
            sessionName: "default",
            remoteSocketPath: "/home/user/.config/herdr/herdr.sock"
        )
        // `herdr terminal attach` only gets HERDR_SOCKET_PATH=localSocketPath;
        // the forwarded client socket must sit exactly where the CLI derives it.
        XCTAssertEqual(
            connection.localClientSocketPath,
            RemoteConnection.clientSocketPath(for: connection.localSocketPath)
        )
    }
}
