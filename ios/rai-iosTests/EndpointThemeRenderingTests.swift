import RaiCore
import SwiftTerm
import UIKit
import XCTest
@testable import rai

@MainActor
final class EndpointThemeRenderingTests: XCTestCase {
    func testModeOverridesChangeColorsWithoutChangingTextOrGrid() throws {
        let terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 360, height: 400))
        terminal.feed(text: "theme fixture\r\nunchanged pane")
        let content = terminal.getTerminal().getBufferAsData()
        let columns = terminal.getTerminal().cols
        var theme = EndpointTheme()
        theme.light = ["text": "#123456", "panel_bg": "#abcdef"]
        theme.dark = ["text": "#fedcba", "panel_bg": "#654321"]
        for (dark, expected) in [(false, 0x12), (true, 0xfe), (false, 0x12)] {
            EndpointTerminalAppearance.apply(terminal, dark: dark, theme: theme)
            var red: CGFloat = 0
            XCTAssertTrue(terminal.nativeForegroundColor.getRed(&red, green: nil, blue: nil, alpha: nil))
            XCTAssertEqual(red, Double(expected) / 255, accuracy: 0.001)
            XCTAssertEqual(terminal.getTerminal().getBufferAsData(), content)
            XCTAssertEqual(terminal.getTerminal().cols, columns)
        }
    }
}
