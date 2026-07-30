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
        let pool = TerminalPool(socketPath: socket)
        let view = pool.view(for: "term-test")
        XCTAssertEqual(view?.scrollbackSelection.client.socketPath, socket)
        pool.removeAll()
    }
}
