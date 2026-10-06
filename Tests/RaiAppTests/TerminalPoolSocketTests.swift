import AppKit
import XCTest

@testable import RaiApp

/// A pane's scrollback controller must talk to the SAME herd as the pool that
/// created it. (Regression: the controller's default client pointed at the
/// default socket, so on a remote/non-default herd its scroll-event stream
/// and pane.read RPCs silently watched the wrong session.)
@MainActor
final class TerminalPoolSocketTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    func testScrollbackClientFollowsPoolSocket() {
        let socket = "/nonexistent/rai-tests-herd.sock"
        let pool = TerminalPool(socketPath: socket, attachExecutable: "/usr/bin/true")
        let view = pool.view(for: "term-test")
        XCTAssertEqual(view?.scrollbackSelection.client.socketPath, socket)
        pool.removeAll()
    }

    func testRemoteAttachDoesNotRequestTakeover() {
        XCTAssertEqual(
            TerminalPool.attachArguments(terminalID: "term-1", takeover: false),
            ["terminal", "attach", "term-1"]
        )
        XCTAssertEqual(
            TerminalPool.attachArguments(terminalID: "term-1", takeover: true),
            ["terminal", "attach", "term-1", "--takeover"]
        )
    }

    func testRemotePoolConfigurationDisablesTakeoverUntilLocalIsRestored() {
        let pool = TerminalPool(socketPath: "/nonexistent/rai-tests-herd.sock", attachExecutable: "/usr/bin/true")
        XCTAssertTrue(pool.takeoverOnAttachForTesting)

        pool.configureRemoteAttach()
        XCTAssertFalse(pool.takeoverOnAttachForTesting)

        pool.configureLocalAttach()
        XCTAssertTrue(pool.takeoverOnAttachForTesting)
        pool.removeAll()
    }
}
