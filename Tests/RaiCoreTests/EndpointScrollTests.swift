import Foundation
import XCTest
@testable import RaiCore

final class EndpointScrollTests: XCTestCase {
    private func surface() throws -> HerdrEndpointSurface {
        let cell: [String: Any] = ["symbol": "│", "foreground": 1, "background": 2,
                                  "modifiers": 1, "skip": false, "hyperlink": 0]
        let rect: [String: Any] = ["x": 0, "y": 0, "width": 2, "height": 4]
        let object: [String: Any] = [
            "bootID": "boot", "projectionRevision": 1, "revision": 1,
            "grid": ["width": 3, "height": 4, "cells": Array(repeating: cell, count: 12), "hyperlinks": ["https://example.com"]],
            "panes": [["paneID": "p", "contentRevision": 1, "rect": rect, "innerRect": rect,
                       "scrollbarRect": ["x": 2, "y": 0, "width": 1, "height": 4],
                       "scroll": ["offset": 10, "maximum": 20, "rows": 4], "focused": true,
                       "mouseReporting": false, "pixelMouse": false, "alternateScreen": false,
                       "pixelWidth": 0, "pixelHeight": 0]],
            "splits": [], "graphics": ["assets": [], "placements": [], "retained": []],
        ]
        return try JSONDecoder().decode(HerdrEndpointSurface.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testHiddenServerScrollbarDoesNotChangePaneGeometryOrOtherCells() throws {
        let surface = try surface()
        let grid = surface.presentationGrid
        XCTAssertEqual(grid.width, surface.grid.width)
        XCTAssertEqual(grid.height, surface.grid.height)
        XCTAssertEqual(grid.cursor, surface.grid.cursor)
        for index in grid.cells.indices {
            if index % 3 == 2 {
                XCTAssertEqual(grid.cells[index].symbol, " ")
                XCTAssertNil(grid.cells[index].hyperlink)
                XCTAssertEqual(grid.cells[index].background, surface.grid.cells[index].background)
            } else { XCTAssertEqual(grid.cells[index], surface.grid.cells[index]) }
        }
        XCTAssertTrue(surface.grid.cells.allSatisfy { $0.symbol == "│" })
    }

    func testThumbUsesPanePositionAndCurrentHistoryOffset() throws {
        let surface = try surface()
        let thumb = try XCTUnwrap(EndpointScroll.thumb(pane: surface.panes[0], grid: surface.grid))
        XCTAssertEqual(thumb.minX, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(thumb.minY, 0.375, accuracy: 0.0001)
        XCTAssertEqual(thumb.height, 0.25, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(thumb.maxY, 1)
    }

    func testOffsetSaturatesWithoutOverflowAndKeepsJSONIntegersExact() {
        XCTAssertEqual(EndpointScroll.offset(from: 5, lines: -10, maximum: 20), 0)
        XCTAssertEqual(EndpointScroll.offset(from: 5, lines: 30, maximum: 20), 20)
        XCTAssertEqual(EndpointScroll.offset(from: .max, lines: .max, maximum: .max), EndpointScroll.maximumOffset)
        XCTAssertEqual(EndpointScroll.offset(from: .max, lines: .min, maximum: .max), 0)
        let rpc = EndpointBridgeCommand.scroll(paneID: "p", offset: .max).rpc
        XCTAssertEqual(rpc.method, "pane.scroll")
        XCTAssertEqual(rpc.params["pane_id"], .string("p"))
        XCTAssertEqual(rpc.params["offset_from_bottom"], .number(Double(EndpointScroll.maximumOffset)))
    }
}
