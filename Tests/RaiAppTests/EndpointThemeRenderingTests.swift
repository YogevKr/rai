import AppKit
import RaiCore
import SwiftTerm
import XCTest
@testable import RaiApp

@MainActor
final class EndpointThemeRenderingTests: XCTestCase {
    func testModeOverridesChangeColorsWithoutChangingTextOrGrid() throws {
        _ = NSApplication.shared
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        terminal.feed(text: "theme fixture\r\nunchanged pane")
        let content = terminal.getTerminal().getBufferAsData()
        let columns = terminal.getTerminal().cols
        var theme = EndpointTheme()
        theme.light = ["text": "#123456", "panel_bg": "#abcdef"]
        theme.dark = ["text": "#fedcba", "panel_bg": "#654321"]
        for (dark, red) in [(false, 0x12), (true, 0xfe), (false, 0x12)] {
            EndpointTerminalAppearance.apply(terminal, dark: dark, theme: theme)
            let color = try XCTUnwrap(terminal.nativeForegroundColor.usingColorSpace(.deviceRGB))
            XCTAssertEqual(color.redComponent, Double(red) / 255, accuracy: 0.001)
            XCTAssertEqual(terminal.getTerminal().getBufferAsData(), content)
            XCTAssertEqual(terminal.getTerminal().cols, columns)
        }
    }

    func testResetRestoresNativeDefaults() throws {
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        var theme = EndpointTheme()
        theme.shared = ["text": "#f00", "panel_bg": "#0f0"]
        EndpointTerminalAppearance.apply(terminal, dark: true, theme: theme)
        EndpointTerminalAppearance.apply(terminal, dark: true)
        let color = try XCTUnwrap(terminal.nativeForegroundColor.usingColorSpace(.deviceRGB))
        XCTAssertEqual(color.redComponent, 248.0 / 255, accuracy: 0.001)
    }
}
