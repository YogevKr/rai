import RaiCore
import SwiftUI
import XCTest
#if os(macOS)
@testable import RaiApp
#else
@testable import rai
#endif

final class EndpointThemePaletteTests: XCTestCase {
    func testImportedSidebarControlsOnlyNavigationBarContrast() throws {
        var theme = EndpointTheme()
        theme.shared = ["sidebar_bg": "#282a36"]
        let palette = EndpointThemePalette(theme: try theme.encoded(), dark: false)
        XCTAssertEqual(palette.sidebarColorScheme, .dark)
        XCTAssertFalse(palette.dark, "Navigation contrast must not change the selected appearance mode.")
        theme.shared = ["sidebar_bg": "#fafafa"]
        XCTAssertEqual(EndpointThemePalette(theme: try theme.encoded(), dark: true).sidebarColorScheme, .light)
    }

    func testResetSidebarUsesPanelAndEmptyThemePreservesSystemContrast() throws {
        var theme = EndpointTheme()
        theme.shared = ["sidebar_bg": "reset", "panel_bg": "#202020"]
        XCTAssertEqual(EndpointThemePalette(theme: try theme.encoded(), dark: false).sidebarColorScheme, .dark)
        XCTAssertNil(EndpointThemePalette(theme: "", dark: false).sidebarColorScheme)
        XCTAssertNil(EndpointThemePalette(theme: "", dark: true).sidebarColorScheme)
    }

    func testDraculaTitleRetainsLightTextUnderExplicitLightAppearance() throws {
        var theme = EndpointTheme()
        theme.name = "dracula"
        theme.autoSwitch = false
        let palette = EndpointThemePalette(theme: try theme.encoded(), dark: false)
        XCTAssertEqual(palette.colors["text"], .rgb(0xf8f8f2))
        XCTAssertEqual(palette.sidebarColorScheme, .dark)
        XCTAssertFalse(palette.dark)
    }
}
