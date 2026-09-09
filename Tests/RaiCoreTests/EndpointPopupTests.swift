import Foundation
import XCTest
@testable import RaiCore

final class EndpointPopupTests: XCTestCase {
    private func surface(popup: Bool) throws -> HerdrEndpointSurface {
        let cell: [String: Any] = ["symbol": "X", "foreground": 1, "background": 2,
                                  "modifiers": 0, "skip": false, "hyperlink": 0]
        var object: [String: Any] = [
            "bootID": "boot", "projectionRevision": 1, "revision": 1,
            "grid": ["width": 8, "height": 6, "cells": Array(repeating: cell, count: 48), "hyperlinks": ["https://base.test"]],
            "panes": [], "splits": [], "graphics": ["assets": [], "placements": [], "retained": []],
        ]
        if popup {
            object["popup"] = ["terminalID": "popup", "title": "Test popup",
                "grid": ["width": 2, "height": 2, "cells": Array(repeating: cell, count: 4),
                         "hyperlinks": ["https://popup.test"], "cursor": ["x": 1, "y": 1, "visible": true, "shape": 0]],
                "mouseReporting": false, "pixelMouse": false, "pixelWidth": 0, "pixelHeight": 0]
        }
        return try JSONDecoder().decode(HerdrEndpointSurface.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testPopupOwnsVisibleTextLinksAndCursorWithoutChangingServerGeometry() throws {
        let surface = try surface(popup: true)
        let grid = surface.presentationGrid
        XCTAssertEqual(grid.width, 8)
        XCTAssertEqual(grid.height, 6)
        XCTAssertEqual(grid.cells.filter { $0.symbol == "X" }.count, 4)
        XCTAssertEqual(grid.hyperlinks, ["https://popup.test"])
        XCTAssertEqual(grid.cursor?.x, 4)
        XCTAssertEqual(grid.cursor?.y, 3)
        XCTAssertEqual(surface.grid.cells.filter { $0.symbol == "X" }.count, 48)
        let restored = try self.surface(popup: false)
        XCTAssertEqual(restored.presentationGrid, restored.grid)
    }

    func testPopupBridgeInputRetainsTerminalIdentity() throws {
        let operation = EndpointBridgeOperation.popupInput(terminalID: "popup-2", input: .paste("שלום"))
        XCTAssertEqual(try JSONDecoder().decode(EndpointBridgeOperation.self, from: JSONEncoder().encode(operation)), operation)
    }
}
