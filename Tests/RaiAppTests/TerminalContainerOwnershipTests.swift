import AppKit
import XCTest

@testable import RaiApp

/// Relaying a tab (split, close a pane, zoom, swap) makes SwiftUI build the
/// replacement `TerminalContainerView` first and update the outgoing one
/// afterwards. That last update used to steal the pooled terminal back into a
/// container that was about to be dismantled; `detach()` then pulled the view
/// out of the window entirely, and since SwiftUI had no reason to update the
/// surviving container again, the pane stayed blank until the tab was
/// re-opened. Symptoms: splitting a single-pane tab blanked the original pane,
/// and closing one of two panes left the survivor blank or drawn at its old
/// half-width.
@MainActor
final class TerminalContainerOwnershipTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private func makeTerminal() -> FocusAwareTerminalView {
        FocusAwareTerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
    }

    func testNewerContainerAdoptsTerminalFromOlderOne() {
        let terminal = makeTerminal()
        let outgoing = TerminalContainerView(frame: .zero)
        let incoming = TerminalContainerView(frame: .zero)

        outgoing.install(terminal)
        XCTAssertTrue(terminal.superview === outgoing)

        incoming.install(terminal)
        XCTAssertTrue(terminal.superview === incoming)
        XCTAssertNil(outgoing.hostedTerminalView)
    }

    func testOutgoingContainerCannotStealTerminalBack() {
        let terminal = makeTerminal()
        let outgoing = TerminalContainerView(frame: .zero)
        let incoming = TerminalContainerView(frame: .zero)

        outgoing.install(terminal)
        incoming.install(terminal)

        // SwiftUI's final updateNSView on the container it is about to tear down.
        outgoing.install(terminal)
        XCTAssertTrue(terminal.superview === incoming)

        // …followed by dismantleNSView, which must not orphan the live terminal.
        outgoing.detach()
        XCTAssertTrue(terminal.superview === incoming)
        XCTAssertTrue(incoming.hostedTerminalView === terminal)
    }

    func testDetachOnlyRemovesATerminalItStillHosts() {
        let terminal = makeTerminal()
        let container = TerminalContainerView(frame: .zero)

        container.install(terminal)
        container.detach()

        XCTAssertNil(terminal.superview)
        XCTAssertNil(container.hostedTerminalView)
    }

    func testInstallIsIdempotentForTheCurrentHost() {
        let terminal = makeTerminal()
        let container = TerminalContainerView(frame: .zero)

        container.install(terminal)
        container.install(terminal)

        XCTAssertTrue(terminal.superview === container)
        XCTAssertEqual(container.subviews.count, 1)
    }

    /// An orphaned terminal (evicted mid-relayout, or pulled out by a container
    /// on its way down) can only come back through the container that is on
    /// screen: SwiftUI will not necessarily update that representable again.
    func testLayoutRehomesAnOrphanedTerminal() {
        let terminal = makeTerminal()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let container = TerminalContainerView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )
        window.contentView?.addSubview(container)

        container.install(terminal)
        XCTAssertTrue(terminal.superview === container)

        // Simulate the pool yanking the view out from under a live container.
        terminal.removeFromSuperview()
        XCTAssertNil(terminal.superview)

        container.layout()
        XCTAssertTrue(terminal.superview === container)
    }
}
