import Foundation
import XCTest
@testable import RaiCore

final class EndpointSurfacePatchTests: XCTestCase {
    func testValidPatchCommitsRowsPaneMetadataAndCursorTogether() throws {
        var surface = try makeSurface()
        surface.grid.hyperlinks = ["https://example.test"]
        let cursor = try makeCursor(x: 1, y: 1, visible: true)
        let patch = makePatch(base: 1, next: 2) { builder in
            builder.rows = [((x: 1, y: 0), [.init(symbol: "Y", hyperlink: 0)])]
            builder.updates = [PaneSpec(pane: surface.panes[0], contentRevision: 7)]
            builder.cursor = cursor
        }
        try surface.applyPatch(patch)
        XCTAssertEqual(surface.revision, 2)
        XCTAssertEqual(surface.grid.cells.map(\.symbol), ["X", "Y", "X", "X"])
        XCTAssertEqual(surface.grid.cells[1].hyperlink, 0)
        XCTAssertEqual(surface.grid.cursor, cursor)
        XCTAssertEqual(surface.panes[0].contentRevision, 7)
    }

    func testMaximumRevisionFailsWithoutOverflow() throws {
        var surface = try makeSurface()
        surface.revision = .max
        let original = surface
        XCTAssertThrowsError(try surface.applyPatch(makePatch(base: .max, next: 0))) { error in
            XCTAssertEqual(error as? HerdrEndpointError, .staleIdentity)
        }
        XCTAssertEqual(surface, original)
    }

    func testHiddenCursorCanRemainOutsideGrid() throws {
        var surface = try makeSurface()
        let cursor = try makeCursor(x: .max, y: .max, visible: false)
        try surface.applyPatch(makePatch(base: 1, next: 2) { $0.cursor = cursor })
        XCTAssertEqual(surface.grid.cursor, cursor)
    }

    func testPatchRequiresTheNextRevision() throws {
        var surface = try makeSurface()
        let original = surface
        XCTAssertThrowsError(try surface.applyPatch(makePatch(base: 1, next: 3))) { error in
            XCTAssertEqual(error as? HerdrEndpointError, .staleIdentity)
        }
        XCTAssertEqual(surface, original)
    }

    func testPatchRejectsInvalidHyperlinkBeforeMutation() throws {
        var surface = try makeSurface()
        let original = surface
        let patch = makePatch(base: 1, next: 2) { builder in
            builder.rows = [((x: 0, y: 0), [.init(hyperlink: 0)])]
        }
        XCTAssertThrowsError(try surface.applyPatch(patch)) { error in
            XCTAssertEqual(error as? HerdrEndpointError, .malformed)
        }
        XCTAssertEqual(surface, original)
    }

    func testPatchRejectsVisibleCursorOutsideGrid() throws {
        var surface = try makeSurface()
        let original = surface
        let cursor = try makeCursor(x: 2, y: 0, visible: true)
        let patch = makePatch(base: 1, next: 2) { builder in
            builder.rows = [((x: 0, y: 0), [.init(symbol: "Y")])]
            builder.cursor = cursor
        }
        XCTAssertThrowsError(try surface.applyPatch(patch)) { error in
            XCTAssertEqual(error as? HerdrEndpointError, .malformed)
        }
        XCTAssertEqual(surface, original)
    }

    func testPatchRejectsSurfacesWithAnActivePopup() throws {
        var surface = try makeSurface(includePopup: true)
        let original = surface
        XCTAssertThrowsError(try surface.applyPatch(makePatch(base: 1, next: 2))) { error in
            XCTAssertEqual(error as? HerdrEndpointError, .staleIdentity)
        }
        XCTAssertEqual(surface, original)
    }

    func testPatchRejectsDuplicatePaneUpdates() throws {
        let surface = try makeSurface()
        let pane = surface.panes[0]
        var value = surface
        let patch = makePatch(base: 1, next: 2) { builder in
            builder.updates = [PaneSpec(pane: pane), PaneSpec(pane: pane)]
        }
        XCTAssertThrowsError(try value.applyPatch(patch)) { error in
            XCTAssertEqual(error as? HerdrEndpointError, .staleIdentity)
        }
        XCTAssertEqual(value, surface)
    }

    func testPatchRejectsPaneGeometryOutsideGrid() throws {
        let surface = try makeSurface()
        let pane = surface.panes[0]
        var value = surface
        let invalidRect = try makeRect(x: 1, y: 0, width: 2, height: 2)
        let patch = makePatch(base: 1, next: 2) { builder in
            builder.updates = [PaneSpec(pane: pane, rect: invalidRect, innerRect: invalidRect)]
        }
        XCTAssertThrowsError(try value.applyPatch(patch)) { error in
            XCTAssertEqual(error as? HerdrEndpointError, .malformed)
        }
        XCTAssertEqual(value, surface)
    }

    func testPatchRejectsGeometryChangesInsideGridBeforeChangingCells() throws {
        var surface = try makeSurface()
        let original = surface
        let smaller = try makeRect(x: 0, y: 0, width: 1, height: 1)
        let patch = makePatch(base: 1, next: 2) { builder in
            builder.rows = [((x: 0, y: 0), [.init(symbol: "Y")])]
            builder.updates = [PaneSpec(pane: surface.panes[0], innerRect: smaller)]
        }
        XCTAssertThrowsError(try surface.applyPatch(patch))
        XCTAssertEqual(surface, original)
    }

    func testGridDecodeRejectsInvalidLinksAndVisibleCursors() throws {
        for invalidLink in [false, true] {
            var builder = PatchBuilder()
            var data = Data()
            builder.integer(1, into: &data)
            builder.cell(.init(hyperlink: invalidLink ? 0 : nil), into: &data)
            builder.integer(1, into: &data) // width
            builder.integer(1, into: &data) // height
            data.append(contentsOf: [1, invalidLink ? 0 : 1, 0, 1, 0])
            builder.integer(0, into: &data) // hyperlinks
            builder.integer(0, into: &data) // graphics bytes
            var reader = EndpointBinaryReader(data: data)
            XCTAssertThrowsError(try EndpointGrid(reader: &reader)) { error in
                XCTAssertEqual(error as? HerdrEndpointError, .malformed)
            }
        }
    }

    private struct CellSpec {
        var symbol = "X"
        var hyperlink: UInt32?
    }

    private struct PaneSpec {
        let pane: EndpointSurfacePane
        let rect: EndpointRect
        let innerRect: EndpointRect
        let contentRevision: UInt64

        init(pane: EndpointSurfacePane, rect: EndpointRect? = nil, innerRect: EndpointRect? = nil,
             contentRevision: UInt64? = nil) {
            self.pane = pane
            self.rect = rect ?? pane.rect
            self.innerRect = innerRect ?? pane.innerRect
            self.contentRevision = contentRevision ?? pane.contentRevision
        }
    }

    private struct PatchBuilder {
        var rows: [(point: (x: UInt16, y: UInt16), cells: [CellSpec])] = []
        var updates: [PaneSpec] = []
        var cursor: EndpointCursor?

        mutating func integer(_ value: UInt64, into data: inout Data) {
            HerdrEndpointWire.appendInteger(value, to: &data)
        }

        mutating func string(_ value: String, into data: inout Data) {
            HerdrEndpointWire.appendString(value, to: &data)
        }

        mutating func rect(_ value: EndpointRect, into data: inout Data) {
            for coordinate in [value.x, value.y, value.width, value.height] {
                integer(UInt64(coordinate), into: &data)
            }
        }

        mutating func cell(_ value: CellSpec, into data: inout Data) {
            string(value.symbol, into: &data)
            integer(0, into: &data)
            integer(0, into: &data)
            integer(0, into: &data)
            data.append(0)
            if let hyperlink = value.hyperlink {
                data.append(1)
                integer(UInt64(hyperlink), into: &data)
            } else {
                data.append(0)
            }
        }

        mutating func pane(_ value: PaneSpec, into data: inout Data) {
            let pane = value.pane
            string(pane.paneID, into: &data)
            integer(value.contentRevision, into: &data)
            rect(value.rect, into: &data)
            rect(value.innerRect, into: &data)
            if let scrollbarRect = pane.scrollbarRect {
                data.append(1)
                rect(scrollbarRect, into: &data)
            } else {
                data.append(0)
            }
            if let scroll = pane.scroll {
                data.append(1)
                integer(scroll.offset, into: &data)
                integer(scroll.maximum, into: &data)
                integer(scroll.rows, into: &data)
            } else {
                data.append(0)
            }
            data.append(pane.focused ? 1 : 0)
            data.append(pane.mouseReporting ? 1 : 0)
            data.append(pane.pixelMouse ? 1 : 0)
            data.append(pane.alternateScreen ? 1 : 0)
            integer(UInt64(pane.pixelWidth), into: &data)
            integer(UInt64(pane.pixelHeight), into: &data)
        }
    }

    private func makePatch(base: UInt64, next: UInt64,
                           configure: (inout PatchBuilder) -> Void = { _ in }) -> Data {
        var builder = PatchBuilder()
        configure(&builder)
        var data = Data()
        builder.integer(19, into: &data)
        builder.string("boot", into: &data)
        builder.integer(1, into: &data)
        builder.integer(base, into: &data)
        builder.integer(next, into: &data)
        builder.integer(UInt64(builder.rows.count), into: &data)
        for row in builder.rows {
            builder.integer(UInt64(row.point.x), into: &data)
            builder.integer(UInt64(row.point.y), into: &data)
            builder.integer(UInt64(row.cells.count), into: &data)
            for cell in row.cells { builder.cell(cell, into: &data) }
        }
        builder.integer(UInt64(builder.updates.count), into: &data)
        for pane in builder.updates { builder.pane(pane, into: &data) }
        if let cursor = builder.cursor {
            data.append(1)
            builder.integer(UInt64(cursor.x), into: &data)
            builder.integer(UInt64(cursor.y), into: &data)
            data.append(cursor.visible ? 1 : 0)
            data.append(cursor.shape)
        } else {
            data.append(0)
        }
        return data
    }

    private func makeSurface(includePopup: Bool = false) throws -> HerdrEndpointSurface {
        let cell: [String: Any] = [
            "symbol": "X", "foreground": 0, "background": 0,
            "modifiers": 0, "skip": false,
        ]
        let rect: [String: Any] = ["x": 0, "y": 0, "width": 2, "height": 2]
        let pane: [String: Any] = [
            "paneID": "p", "contentRevision": 1, "rect": rect, "innerRect": rect,
            "focused": true, "mouseReporting": false, "pixelMouse": false,
            "alternateScreen": false, "pixelWidth": 0, "pixelHeight": 0,
        ]
        var object: [String: Any] = [
            "bootID": "boot", "projectionRevision": 1, "revision": 1,
            "grid": ["width": 2, "height": 2, "cells": Array(repeating: cell, count: 4), "hyperlinks": []],
            "panes": [pane], "splits": [],
            "graphics": ["assets": [], "placements": [], "retained": []],
        ]
        if includePopup {
            object["popup"] = [
                "terminalID": "popup", "title": "Popup",
                "grid": ["width": 1, "height": 1, "cells": [cell], "hyperlinks": []],
                "mouseReporting": false, "pixelMouse": false,
                "pixelWidth": 0, "pixelHeight": 0,
            ]
        }
        return try JSONDecoder().decode(
            HerdrEndpointSurface.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    private func makeCursor(x: UInt16, y: UInt16, visible: Bool) throws -> EndpointCursor {
        let object: [String: Any] = ["x": x, "y": y, "visible": visible, "shape": 0]
        return try JSONDecoder().decode(
            EndpointCursor.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    private func makeRect(x: UInt16, y: UInt16, width: UInt16, height: UInt16) throws -> EndpointRect {
        let object: [String: Any] = ["x": x, "y": y, "width": width, "height": height]
        return try JSONDecoder().decode(
            EndpointRect.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }
}
