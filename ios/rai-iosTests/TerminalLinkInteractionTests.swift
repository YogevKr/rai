import SwiftTerm
import UIKit
import XCTest
@testable import rai

@MainActor
final class TerminalLinkInteractionTests: XCTestCase {
    func testEndpointCallbackReceivesActualTapAndDoesNotBypassSelection() {
        let terminal = PhoneLinkTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        terminal.feed(text: "\u{1b}]8;;herdr://plugin/test\u{1b}\\Plugin\u{1b}]8;;\u{1b}\\")
        var received: [(String, CGPoint)] = []
        terminal.endpointLinkAt = { received.append(($0, $1)); return true }
        let interaction = TerminalLinkInteraction(terminal: terminal)
        let size = terminal.getOptimalFrameSize()
        let point = CGPoint(x: size.width / CGFloat(terminal.getTerminal().cols) * 2,
                            y: size.height / CGFloat(terminal.getTerminal().rows) * 0.5)
        interaction.activateLink(at: point)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.0, "herdr://plugin/test")
        XCTAssertEqual(received.first?.1, point)
        terminal.setSelectionRange(start: Position(col: 0, row: 0), end: Position(col: 4, row: 0))
        interaction.activateLink(at: point)
        XCTAssertEqual(received.count, 1)
        XCTAssertNotNil(terminal.getSelectionRange())
    }
}
