import XCTest
@testable import RaiCore

final class EndpointThemeTests: XCTestCase {
    func testSharedAndModeOverridesFollowHerdrPrecedence() throws {
        let theme = try EndpointThemeImport.parse("""
        [theme]
        name = "catppuccin"
        auto_switch = true
        [theme.custom]
        accent = "#123"
        text = "#456789"
        [theme.custom.light]
        text = "rgb(10, 20, 30)"
        [theme.custom.dark]
        panel_bg = "reset"
        """)
        XCTAssertEqual(theme.palette(dark: false)["accent"], .rgb(0x112233))
        XCTAssertEqual(theme.palette(dark: true)["accent"], .rgb(0x112233))
        XCTAssertEqual(theme.palette(dark: false)["text"], .rgb(0x0a141e))
        XCTAssertEqual(theme.palette(dark: true)["text"], .rgb(0x456789))
        XCTAssertEqual(theme.palette(dark: false)["panel_bg"], .rgb(0xeff1f5))
        XCTAssertEqual(theme.palette(dark: true)["panel_bg"], .reset)
    }

    func testManualModeDoesNotUseModeOverrides() throws {
        let theme = try EndpointThemeImport.parse("""
        [theme]
        name = 'tokyo-night'
        [theme.custom.light]
        text = '#fff'
        """)
        XCTAssertEqual(theme.palette(dark: false), theme.palette(dark: true))
        XCTAssertEqual(theme.palette(dark: false)["text"], .rgb(0xc0caf5))
    }

    func testExplicitModeNamesAndAliases() throws {
        let theme = try EndpointThemeImport.parse("""
        [theme]
        name = "DRACULA"
        auto_switch = true
        light_name = "latte"
        dark_name = "Tokyo Night"
        """)
        XCTAssertEqual(theme.lightName, "catppuccin-latte")
        XCTAssertEqual(theme.darkName, "tokyo-night")
        XCTAssertEqual(theme.palette(dark: false)["text"], .rgb(0x4c4f69))
        XCTAssertEqual(theme.palette(dark: true)["text"], .rgb(0xc0caf5))
    }

    func testAllBuiltInPalettesHaveEveryToken() throws {
        XCTAssertEqual(EndpointThemeCatalog.names.count, 18)
        XCTAssertEqual(EndpointThemeCatalog.tokens.count, 19)
        for name in EndpointThemeCatalog.names {
            let theme = try EndpointThemeImport.parse("[theme]\nname = \"\(name)\"")
            XCTAssertEqual(Set(theme.palette(dark: true).keys), Set(EndpointThemeCatalog.tokens), name)
        }
    }

    func testSupportedColorFormatsAndResetAliases() throws {
        for value in ["#aB3", "#aaBB33", "rgb(170, 187, 51)"] {
            XCTAssertEqual(try EndpointThemeColor.parse(value), .rgb(0xaabb33), value)
        }
        for value in ["reset", "default", "none", "transparent"] {
            XCTAssertEqual(try EndpointThemeColor.parse(value), .reset)
        }
        XCTAssertEqual(try EndpointThemeColor.parse("WHITE"), .named(15))
        XCTAssertEqual(try EndpointThemeColor.parse("gray"), .named(7))
        XCTAssertEqual(try EndpointThemeColor.parse("purple"), .named(5))
        for value in ["#12", "#12345g", "#１２３", "rgb(256,0,0)", "rgb(1,2,)", "cyanide"] {
            XCTAssertThrowsError(try EndpointThemeColor.parse(value), value)
        }
    }

    func testImportCommentsAndUnrelatedTables() throws {
        let theme = try EndpointThemeImport.parse("""
        [ui]
        pane_borders = false
        [theme.custom] # colors
        text = "#abc" # visible text
        panel_bg = 'reset'
        [notifications]
        enabled = true
        """)
        XCTAssertEqual(theme.shared, ["text": "#abc", "panel_bg": "reset"])
        XCTAssertEqual(theme.name, "catppuccin")
    }

    func testInvalidImportsFailWithoutPartialAcceptance() {
        for source in [
            "[theme]\nname = 'unknown'", "[theme]\nname = 'dracula'\n[theme", "[theme]\nname = ''",
            "[theme]\nauto_switch = 'true'", "[theme]\nauto_switch = True",
            "[theme]\ncustom = { text = '#fff' }", "[theme.custom]\ntext = '#ggg'",
            "[theme.custom]\ntext = '#fff'\ntext = '#000'", "[theme]\n[theme]",
            "[theme.custom]\nunknown = 'red'", "[theme.custom.future]\ntext = 'red'",
            "[theme]\nname = \"dracula\" trailing", "[ui]\npane_borders = true",
            "[theme.custom]\ntext = \"\"\"#abc\"\"\"",
            "[other]\nvalue = \"\"\"\n[theme]\nname = 'dracula'\n\"\"\"",
        ] {
            XCTAssertThrowsError(try EndpointThemeImport.parse(source), source)
        }
    }

    func testImportPreservesLegacyBooleanBorderMeanings() throws {
        for (value, expected) in [("true", EndpointBorderMode.always), ("false", .off), ("'auto'", .auto), ("'always'", .always), ("'off'", .off)] {
            let settings = try EndpointThemeImport.parseSettings("[theme]\nname = 'dracula'\n[ui]\npane_borders = \(value)")
            XCTAssertEqual(settings.borders, expected)
        }
        XCTAssertThrowsError(try EndpointThemeImport.parseSettings("[theme]\n[ui]\npane_borders = 1"))
    }

    func testErrorsIncludeLineAndSizeLimits() {
        XCTAssertThrowsError(try EndpointThemeImport.parse("# header\n[theme.custom]\ntext = 'invalid'")) { error in
            XCTAssertEqual(error.localizedDescription, "Line 3: Unknown color: invalid.")
        }
        XCTAssertThrowsError(try EndpointThemeImport.parse(String(repeating: "x", count: EndpointThemeImport.maximumBytes + 1)))
    }

    func testPersistenceKeepsBothModesAndReset() throws {
        var theme = EndpointTheme()
        theme.light = ["text": "#123"]
        theme.dark = ["text": "reset"]
        XCTAssertEqual(EndpointTheme.stored(try theme.encoded()), theme)
        XCTAssertEqual(EndpointTheme.stored("invalid"), EndpointTheme())
        XCTAssertEqual(theme.palette(dark: false)["text"], .rgb(0x112233))
        XCTAssertEqual(theme.palette(dark: true)["text"], .reset)
    }
}
