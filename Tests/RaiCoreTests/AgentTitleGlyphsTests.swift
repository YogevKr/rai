import XCTest
@testable import RaiCore

final class AgentTitleGlyphsTests: XCTestCase {
    func testStripsHalfCircleSpinnerFrames() {
        for glyph in ["◐", "◓", "◑", "◒"] {
            XCTAssertEqual(
                AgentTitleGlyphs.strip("\(glyph) Validate network settings"),
                "Validate network settings",
                "glyph \(glyph) should be stripped"
            )
        }
    }

    func testStripsAttentionMarkerAndBrailleFrames() {
        XCTAssertEqual(
            AgentTitleGlyphs.strip("✳ publish-lease-refactor"),
            "publish-lease-refactor"
        )
        XCTAssertEqual(AgentTitleGlyphs.strip("⠧ compiling"), "compiling")
    }

    func testStripsStackedGlyphs() {
        XCTAssertEqual(AgentTitleGlyphs.strip("✳ ◐ deploy"), "deploy")
    }

    func testKeepsPlainTitles() {
        XCTAssertEqual(
            AgentTitleGlyphs.strip("condition-curator"),
            "condition-curator"
        )
    }

    func testKeepsInteriorGlyphs() {
        XCTAssertEqual(
            AgentTitleGlyphs.strip("Fix ◐ rendering"),
            "Fix ◐ rendering"
        )
    }

    func testKeepsNonGlyphSymbolPrefixes() {
        XCTAssertEqual(AgentTitleGlyphs.strip("🚀 deploy"), "🚀 deploy")
    }

    func testKeepsGlyphFusedToText() {
        XCTAssertEqual(AgentTitleGlyphs.strip("◐Foo"), "◐Foo")
    }

    func testGlyphOnlyAndEmptyTitlesBecomeNil() {
        XCTAssertNil(AgentTitleGlyphs.strip("◐"))
        XCTAssertNil(AgentTitleGlyphs.strip("✳ "))
        XCTAssertNil(AgentTitleGlyphs.strip(""))
        XCTAssertNil(AgentTitleGlyphs.strip(nil))
    }

    // Herdr 0.7.x strips "✳" but not the 2.1.228 half-circle spinner; the
    // pane decoder must finish the job while leaving the raw title alone.
    func testPaneDecodeStripsLeakedSpinnerGlyph() throws {
        let json = """
        {
            "pane_id": "w27:p7",
            "terminal_id": "term_1",
            "workspace_id": "w27",
            "tab_id": "w27:t7",
            "focused": false,
            "cwd": "/Users/yogev",
            "agent": "claude",
            "terminal_title": "◑ Get started with new KVM",
            "terminal_title_stripped": "◑ Get started with new KVM",
            "agent_status": "working",
            "revision": 104
        }
        """
        let pane = try JSONDecoder().decode(
            Pane.self, from: Data(json.utf8)
        )
        XCTAssertEqual(
            pane.terminalTitleStripped, "Get started with new KVM"
        )
        XCTAssertEqual(pane.terminalTitle, "◑ Get started with new KVM")
    }

    func testAgentDecodeStripsLeakedSpinnerGlyph() throws {
        let json = """
        {
            "terminal_id": "term_1",
            "agent": "claude",
            "terminal_title": "◐ Identify circles in image",
            "terminal_title_stripped": "◐ Identify circles in image",
            "agent_status": "working",
            "workspace_id": "w27",
            "tab_id": "w27:t8",
            "pane_id": "w27:p8",
            "focused": false,
            "revision": 143
        }
        """
        let agent = try JSONDecoder().decode(
            HerdrAgent.self, from: Data(json.utf8)
        )
        XCTAssertEqual(
            agent.terminalTitleStripped, "Identify circles in image"
        )
        XCTAssertEqual(agent.terminalTitle, "◐ Identify circles in image")
    }
}
