import Foundation
import XCTest
@testable import RaiCore

final class EndpointBorderTests: XCTestCase {
    func testBorderModesPreserveBooleanImportsAndAutomaticVisibility() {
        XCTAssertEqual(EndpointBorderMode(configuration: .bool(true)), .always)
        XCTAssertEqual(EndpointBorderMode(configuration: .bool(false)), .off)
        XCTAssertEqual(EndpointBorderMode(configuration: .string("auto")), .auto)
        XCTAssertNil(EndpointBorderMode(configuration: .string("unknown")))
        XCTAssertFalse(EndpointBorderMode.auto.isVisible(paneCount: 1))
        XCTAssertTrue(EndpointBorderMode.auto.isVisible(paneCount: 2))
        XCTAssertTrue(EndpointBorderMode.always.isVisible(paneCount: 1))
        XCTAssertFalse(EndpointBorderMode.off.isVisible(paneCount: 2))
    }

    func testNativeBordersRemoveOnlyServerBorderCellsWithoutReflow() throws {
        let cell: [String: Any] = ["symbol": "X", "foreground": 1, "background": 2,
                                  "modifiers": 0, "skip": false, "hyperlink": 0]
        let rect = ["x": 0, "y": 0, "width": 4, "height": 4]
        let inner = ["x": 1, "y": 1, "width": 2, "height": 2]
        let object: [String: Any] = ["bootID": "boot", "projectionRevision": 1, "revision": 1,
            "grid": ["width": 4, "height": 4, "cells": Array(repeating: cell, count: 16), "hyperlinks": ["https://example.test"]],
            "panes": [["paneID": "p", "contentRevision": 1, "rect": rect, "innerRect": inner,
                       "focused": true, "mouseReporting": false, "pixelMouse": false,
                       "alternateScreen": false, "pixelWidth": 0, "pixelHeight": 0]],
            "splits": [], "graphics": ["assets": [], "placements": [], "retained": []]]
        let surface = try JSONDecoder().decode(HerdrEndpointSurface.self, from: JSONSerialization.data(withJSONObject: object))
        let grid = surface.presentationGrid
        XCTAssertEqual(grid.width, 4)
        XCTAssertEqual(grid.height, 4)
        for index in grid.cells.indices {
            if [5, 6, 9, 10].contains(index) { XCTAssertEqual(grid.cells[index], surface.grid.cells[index]) }
            else { XCTAssertEqual(grid.cells[index].symbol, " "); XCTAssertNil(grid.cells[index].hyperlink) }
        }
        XCTAssertTrue(surface.grid.cells.allSatisfy { $0.symbol == "X" })
    }
}
