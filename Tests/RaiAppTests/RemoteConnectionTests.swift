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

    func testForwardArgumentsUseTheSharedControlMaster() throws {
        let connection = RemoteConnection(
            target: "user@host",
            sessionName: "default",
            remoteSocketPath: "/home/user/.config/herdr/herdr.sock"
        )
        let rpc = try connection.forwardArguments(
            localPath: connection.localSocketPath,
            remotePath: connection.remoteSocketPath
        )
        let client = try connection.forwardArguments(
            localPath: connection.localClientSocketPath,
            remotePath: connection.remoteClientSocketPath
        )
        XCTAssertEqual(rpc.last, "user@host")
        XCTAssertEqual(client.last, "user@host")
        XCTAssertTrue(rpc.contains("-O"))
        XCTAssertTrue(rpc.contains("forward"))
        XCTAssertTrue(rpc.contains("-C"))
        XCTAssertTrue(rpc.contains("-S"))
        XCTAssertTrue(rpc.contains("ControlMaster=auto"))
        XCTAssertTrue(rpc.contains("ControlPersist=600"))
        XCTAssertTrue(rpc.contains("IgnoreUnknown=ObscureKeystrokeTiming"))
        XCTAssertTrue(rpc.contains("ObscureKeystrokeTiming=no"))
        XCTAssertTrue(rpc.contains("ServerAliveInterval=15"))
        XCTAssertTrue(rpc.contains("ServerAliveCountMax=3"))
        XCTAssertTrue(rpc.contains("StreamLocalBindUnlink=yes"))
        XCTAssertTrue(rpc.contains("\(connection.localSocketPath):\(connection.remoteSocketPath)"))
        XCTAssertTrue(client.contains("\(connection.localClientSocketPath):\(connection.remoteClientSocketPath)"))
    }

    func testSSHControlOptionsArePrivateAndStablePerTarget() throws {
        let first = try RemoteConnection.sshConfigurationArguments(target: "user@host")
        let same = try RemoteConnection.sshConfigurationArguments(target: "user@host")
        let other = try RemoteConnection.sshConfigurationArguments(target: "user@other-host")

        func controlPath(_ arguments: [String]) -> String? {
            guard let index = arguments.firstIndex(of: "-S"), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        let firstPath = try XCTUnwrap(controlPath(first))
        XCTAssertEqual(firstPath, controlPath(same))
        XCTAssertNotEqual(firstPath, controlPath(other))
        XCTAssertTrue(firstPath.hasPrefix("/tmp/rai-hssh-"))
        XCTAssertLessThan(firstPath.utf8.count, 100)
    }

    func testForegroundArgumentsDoNotDelayInteractiveKeystrokes() throws {
        let arguments = try RemoteConnection.foregroundArguments(
            target: "user@host",
            sessionName: "default",
            arguments: ["pane", "run", "w1:p1", "printf ok"]
        )

        XCTAssertTrue(arguments.contains("ObscureKeystrokeTiming=no"))
    }

    func testForegroundAttachArgumentsBuildTheRemoteTerminalCommand() throws {
        let arguments = try RemoteConnection.foregroundAttachArguments(
            target: "user@host",
            sessionName: "remote",
            terminalID: "term_123"
        )

        XCTAssertEqual(
            arguments.last,
            "'herdr' '--session' 'remote' 'terminal' 'attach' 'term_123'"
        )
        XCTAssertTrue(arguments.contains("ObscureKeystrokeTiming=no"))
    }

    func testCapturedRemoteContextCreatesDistinctForwardedSocketPairs() {
        let main = RemoteConnection(target: "user@host", sessionName: "review", remoteSocketPath: "/remote/review/herdr.sock")
        let captured = main.context
        let child = RemoteConnection(target: captured.target, sessionName: captured.sessionName, remoteSocketPath: captured.remoteSocketPath)
        XCTAssertEqual(child.context, main.context)
        XCTAssertNotEqual(child.localSocketPath, main.localSocketPath)
        XCTAssertNotEqual(child.localClientSocketPath, main.localClientSocketPath)
        XCTAssertTrue(EndpointWindowModel(socketPath: main.localSocketPath, remoteContext: captured).usesRemoteHost)
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
