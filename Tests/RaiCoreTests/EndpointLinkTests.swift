import Foundation
import XCTest
@testable import RaiCore

final class EndpointLinkTests: XCTestCase {
    private func grid(link: String?) throws -> EndpointGrid {
        let object: [String: Any] = [
            "width": 1, "height": 1, "hyperlinks": link.map { [$0] } ?? [],
            "cells": [["symbol": "X", "foreground": 0, "background": 0,
                       "modifiers": 0, "skip": false, "hyperlink": 0]],
        ]
        return try JSONDecoder().decode(EndpointGrid.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testZeroBasedLinkAndReplacementRepaint() throws {
        let old = try grid(link: "https://example.com/old")
        let next = try grid(link: "https://example.com/new")
        let output = String(decoding: EndpointANSI.render(next, previous: old), as: UTF8.self)
        XCTAssertTrue(output.contains("\u{1b}]8;;https://example.com/new\u{1b}\\X\u{1b}]8;;\u{1b}\\"))
        XCTAssertFalse(output.contains("/old"))
        let removed = String(decoding: EndpointANSI.render(try grid(link: nil), previous: next), as: UTF8.self)
        XCTAssertTrue(removed.contains("X\u{1b}]8;;\u{1b}\\"))
        XCTAssertFalse(removed.contains("https://"))
    }

    func testLinkCannotInjectTerminalControls() throws {
        for control in ["\u{1b}", "\u{7}", "\n", "\u{9b}"] {
            let output = String(decoding: EndpointANSI.render(try grid(link: "https://bad/" + control + "PAYLOAD")), as: UTF8.self)
            XCTAssertFalse(output.contains("PAYLOAD"))
            XCTAssertTrue(output.contains("X"))
        }
    }

    func testPopupLinksCaptureOnlyDisplayedPopupCells() throws {
        let surface = try popupSurface()
        let link = try XCTUnwrap(EndpointPopupLinkInvocation.capture(in: surface, column: 2, row: 2,
            expectedURL: "https://example.com"))
        XCTAssertEqual(link.terminalID, "popup")
        XCTAssertNoThrow(try link.validate(in: surface))
        XCTAssertNil(EndpointPopupLinkInvocation.capture(in: surface, column: 0, row: 0, expectedURL: link.url))
        XCTAssertNil(EndpointPopupLinkInvocation.capture(in: surface, column: 2, row: 2, expectedURL: "https://other.example"))
        XCTAssertNil(EndpointPluginLinkInvocation.capture(in: surface, column: 2, row: 2, expectedURL: link.url))
        XCTAssertTrue(EndpointPluginLinkInvocation.links(in: surface).isEmpty)
    }

    func testPopupLinkRejectsReplacementRevisionBootAndChangedTarget() throws {
        let original = try popupSurface()
        let link = try XCTUnwrap(EndpointPopupLinkInvocation.capture(in: original, column: 2, row: 2,
            expectedURL: "https://example.com"))
        for changed in [try popupSurface(terminal: "replacement"), try popupSurface(revision: 2),
                        try popupSurface(boot: "restart"), try popupSurface(projection: 2),
                        try popupSurface(url: "https://other.example"), try popupSurface(includePopup: false)] {
            XCTAssertThrowsError(try link.validate(in: changed))
        }
    }

    func testPopupPlainURLMustMatchTheClickedText() throws {
        let url = "https://example.com"
        let surface = try popupSurface(explicit: false)
        XCTAssertNotNil(EndpointPopupLinkInvocation.capture(in: surface, column: 6, row: 2, expectedURL: url))
        XCTAssertNil(EndpointPopupLinkInvocation.capture(in: surface, column: 2, row: 3, expectedURL: url))
        XCTAssertNil(EndpointPopupLinkInvocation.capture(in: surface, column: 6, row: 2, expectedURL: "https://example.com/other"))
        XCTAssertNil(EndpointPopupLinkInvocation.capture(in: surface, column: 6, row: 2, expectedURL: url + "\n"))
    }

    func testPopupPlainUnicodeURLPreservesSwiftTermDisplayText() throws {
        for url in ["https://example.com/café", "https://example.com/שלום"] {
            let surface = try popupSurface(url: url, explicit: false)
            let link = try XCTUnwrap(EndpointPopupLinkInvocation.capture(in: surface, column: 6, row: 2, expectedURL: url))
            XCTAssertEqual(link.url, url)
            XCTAssertNoThrow(try link.validate(in: surface))
        }
    }

    private func popupSurface(terminal: String = "popup", revision: Int = 1, boot: String = "boot",
                              projection: Int = 1, url: String = "https://example.com",
                              explicit: Bool = true, includePopup: Bool = true) throws -> HerdrEndpointSurface {
        let blank: [String: Any] = ["symbol": " ", "foreground": 0, "background": 0, "modifiers": 0, "skip": false]
        let width = max(20, url.count)
        var cells = Array(repeating: blank, count: width * 2)
        if explicit { cells[0]["symbol"] = "X"; cells[0]["hyperlink"] = 0 }
        else { for (index, character) in url.enumerated() { cells[index]["symbol"] = String(character) } }
        var value: [String: Any] = ["bootID": boot, "projectionRevision": projection, "revision": revision,
            "grid": ["width": width + 4, "height": 6, "cells": Array(repeating: blank, count: (width + 4) * 6), "hyperlinks": []],
            "panes": [], "splits": [], "graphics": ["assets": [], "placements": [], "retained": []]]
        if includePopup {
            value["popup"] = ["terminalID": terminal, "title": "Popup",
                "grid": ["width": width, "height": 2, "cells": cells, "hyperlinks": explicit ? [url] : []],
                "mouseReporting": false, "pixelMouse": false, "pixelWidth": 0, "pixelHeight": 0]
        }
        return try JSONDecoder().decode(HerdrEndpointSurface.self, from: JSONSerialization.data(withJSONObject: value))
    }
}
