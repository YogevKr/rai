import UIKit
import XCTest

@testable import rai

/// The pane terminal's width contract: an 80-column FLOOR, not a fixed size.
/// Portrait (viewport narrower than the floor) scrolls horizontally; landscape
/// stretches the grid edge-to-edge — the bug was a dead strip right of the
/// 80-col grid in landscape.
final class TerminalLayoutTests: XCTestCase {
    private func terminalWidth(viewport: CGSize, minWidth: CGFloat) -> CGFloat {
        let scroll = UIScrollView(frame: CGRect(origin: .zero, size: viewport))
        let terminal = UIView()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(terminal)
        NSLayoutConstraint.activate(
            TerminalPaneLayout.constraints(
                terminal: terminal, in: scroll, minWidth: minWidth))
        scroll.layoutIfNeeded()
        return terminal.frame.width
    }

    func testPortraitKeepsTheEightyColumnFloor() {
        let width = terminalWidth(
            viewport: CGSize(width: 390, height: 700), minWidth: 628)
        XCTAssertEqual(width, 628, accuracy: 0.5)
    }

    func testLandscapeFillsTheViewport() {
        let width = terminalWidth(
            viewport: CGSize(width: 844, height: 350), minWidth: 628)
        XCTAssertEqual(width, 844, accuracy: 0.5)
    }

    func testExactFitHasNoDeadStrip() {
        let width = terminalWidth(
            viewport: CGSize(width: 628, height: 500), minWidth: 628)
        XCTAssertEqual(width, 628, accuracy: 0.5)
    }
}
