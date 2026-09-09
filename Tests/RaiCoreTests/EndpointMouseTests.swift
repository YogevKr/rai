import Foundation
import XCTest
@testable import RaiCore

final class EndpointMouseTests: XCTestCase {
    func testCellWheelUsesTheSemanticWireContract() throws {
        let mouse = EndpointMouse(kind: .scrollDown, column: 3, row: 2, columns: 10, rows: 20, lines: 3)
        XCTAssertTrue(mouse.isValid)
        var encoded = Data()
        try EndpointBridgeInput.mouse(mouse).input().encode(to: &encoded)
        XCTAssertEqual(Array(encoded), [2, 5, 0, 3, 2, 0, 0, 3])
    }

    func testPixelPressIncludesConsistentTerminalGeometry() throws {
        let mouse = EndpointMouse(kind: .down, button: .left, column: 3, row: 2, columns: 10, rows: 20,
                                  pixelX: 35, pixelY: 25, pixelWidth: 100, pixelHeight: 200, modifiers: 2)
        XCTAssertTrue(mouse.isValid)
        var encoded = Data()
        try EndpointBridgeInput.mouse(mouse).input().encode(to: &encoded)
        XCTAssertEqual(Array(encoded), [2, 0, 0, 1, 35, 25, 3, 2, 1, 10, 20, 100, 200, 2, 1])
        let roundTrip = try JSONDecoder().decode(EndpointBridgeInput.self,
            from: JSONEncoder().encode(EndpointBridgeInput.mouse(mouse)))
        XCTAssertEqual(roundTrip, .mouse(mouse))
    }

    func testInvalidMouseCannotCrossThePhoneBridge() {
        let invalid: [EndpointMouse] = [
            .init(kind: .down, column: 0, row: 0, columns: 1, rows: 1),
            .init(kind: .moved, button: .left, column: 0, row: 0, columns: 1, rows: 1),
            .init(kind: .moved, column: 1, row: 0, columns: 1, rows: 1),
            .init(kind: .moved, column: 0, row: 0, columns: 0, rows: 1),
            .init(kind: .moved, column: 0, row: 0, columns: 1, rows: 1, pixelX: 0),
            .init(kind: .moved, column: 0, row: 0, columns: 1, rows: 1, modifiers: 128),
            .init(kind: .scrollUp, column: 0, row: 0, columns: 1, rows: 1, lines: 0),
            .init(kind: .moved, column: 1, row: 0, columns: 2, rows: 1,
                  pixelX: 1, pixelY: 0, pixelWidth: 100, pixelHeight: 20),
        ]
        for mouse in invalid {
            XCTAssertFalse(mouse.isValid)
            XCTAssertThrowsError(try EndpointBridgeInput.mouse(mouse).input())
        }
    }

    func testPointerTargetsOnlyTheFocusedPaneAndItsInnerRectangle() throws {
        let surface = try surface()
        let target = try XCTUnwrap(surface.mouse(atColumn: 3.5, row: 2.5, kind: .down, button: .left))
        XCTAssertEqual(target.paneID, "w1:p1")
        XCTAssertEqual(target.input.column, 2)
        XCTAssertEqual(target.input.row, 1)
        XCTAssertEqual(target.input.pixelX, 26)
        XCTAssertEqual(target.input.pixelY, 31)
        let release = try XCTUnwrap(target.released)
        XCTAssertEqual(release.paneID, target.paneID)
        XCTAssertEqual(release.input.kind, .up)
        XCTAssertEqual(release.input.pixelX, target.input.pixelX)
        XCTAssertTrue(release.input.isValid)
        XCTAssertNil(surface.mouse(atColumn: 0.5, row: 0.5, kind: .moved))
        XCTAssertNil(surface.mouse(atColumn: 8.5, row: 2.5, kind: .moved))
        XCTAssertNil(surface.mouse(atColumn: .nan, row: 1, kind: .moved))
        XCTAssertNil(surface.mouse(atColumn: 1, row: .infinity, kind: .moved))
    }

    func testMouseReportingDisabledPreservesNativeSelection() throws {
        XCTAssertNil(try surface(reporting: false).mouse(atColumn: 2, row: 2, kind: .down, button: .left))
    }

    func testPixelRoundingPreservesEveryCellBoundary() throws {
        let surface = try surface(pixelWidth: 41, pixelHeight: 83)
        for column in 1...4 {
            for row in 1...4 {
                let input = try XCTUnwrap(surface.mouse(atColumn: Double(column), row: Double(row), kind: .moved)).input
                XCTAssertTrue(input.isValid)
                XCTAssertEqual(input.column, UInt16(column - 1))
                XCTAssertEqual(input.row, UInt16(row - 1))
                XCTAssertNotNil(input.pixelX)
            }
        }
        let tiny = try self.surface(pixelWidth: 1, pixelHeight: 1)
        let input = try XCTUnwrap(tiny.mouse(atColumn: 2, row: 2, kind: .moved)).input
        XCTAssertTrue(input.isValid)
        XCTAssertNil(input.pixelX)
    }

    func testPixelInputUsesOneBasedEdgesAndPreservesMovementWithinOneCell() throws {
        let surface = try surface()
        let first = try XCTUnwrap(surface.mouse(atColumn: 1, row: 1, kind: .moved)).input
        XCTAssertEqual(first.pixelX, 1)
        XCTAssertEqual(first.pixelY, 1)
        let shifted = try XCTUnwrap(surface.mouse(atColumn: 1.2, row: 1.2, kind: .moved)).input
        XCTAssertEqual(shifted.column, first.column)
        XCTAssertEqual(shifted.row, first.row)
        XCTAssertGreaterThan(try XCTUnwrap(shifted.pixelX), try XCTUnwrap(first.pixelX))
        XCTAssertGreaterThan(try XCTUnwrap(shifted.pixelY), try XCTUnwrap(first.pixelY))
        let last = try XCTUnwrap(surface.mouse(atColumn: 4.999, row: 4.999, kind: .moved)).input
        XCTAssertEqual(last.pixelX, 40)
        XCTAssertEqual(last.pixelY, 80)
        XCTAssertTrue(last.isValid)
        XCTAssertFalse(EndpointMouse(kind: .moved, column: 0, row: 0, columns: 4, rows: 4,
            pixelX: 0, pixelY: 1, pixelWidth: 40, pixelHeight: 80).isValid)
        XCTAssertFalse(EndpointMouse(kind: .moved, column: 0, row: 0, columns: 4, rows: 4,
            pixelX: 1, pixelY: 0, pixelWidth: 40, pixelHeight: 80).isValid)
    }

    func testCaptureRejectsFocusAwayAndBackAndOrphanDrags() throws {
        let original = try surface()
        let down = try XCTUnwrap(original.mouse(atColumn: 2, row: 2, kind: .down, button: .left))
        let drag = try XCTUnwrap(original.mouse(atColumn: 3, row: 3, kind: .drag, button: .left))
        var capture = EndpointMouseCapture(target: down, surface: original)
        capture.observe(try surface(paneID: "other"))
        capture.observe(original)
        XCTAssertFalse(capture.isValid)
        XCTAssertNil(capture.drag(drag, in: original))
        XCTAssertNil(capture.release(in: original))
        XCTAssertFalse(EndpointMouseCapture(target: drag, surface: original).isValid)
        var disconnected = EndpointMouseCapture(target: down, surface: original)
        disconnected.observe(nil)
        disconnected.observe(original)
        XCTAssertNil(disconnected.release(in: original))
    }

    func testCaptureKeepsButtonAndClampsReleaseAfterResize() throws {
        let original = try surface()
        let down = try XCTUnwrap(original.mouse(atColumn: 4, row: 4, kind: .down, button: .left))
        var capture = EndpointMouseCapture(target: down, surface: original)
        let wrongButton = try XCTUnwrap(original.mouse(atColumn: 3, row: 3, kind: .drag, button: .right))
        XCTAssertNil(capture.drag(wrongButton, in: original))
        let release = try XCTUnwrap(capture.release(in: surface(width: 2, height: 2)))
        XCTAssertEqual(release.input.column, 1)
        XCTAssertEqual(release.input.row, 1)
        XCTAssertEqual(release.input.button, .left)
        XCTAssertNil(release.input.pixelX)
        XCTAssertNil(release.input.pixelWidth)
        XCTAssertTrue(release.input.isValid)
        XCTAssertNil(capture.release(in: original))
    }

    func testCapturePreservesPixelClickAndDragReleaseOnTheWire() throws {
        let original = try surface()
        let down = try XCTUnwrap(original.mouse(atColumn: 2.25, row: 2.25, kind: .down, button: .left))
        let drag = try XCTUnwrap(original.mouse(atColumn: 3.5, row: 3.5, kind: .drag, button: .left))
        for moved in [false, true] {
            var capture = EndpointMouseCapture(target: down, surface: original)
            if moved { XCTAssertNotNil(capture.drag(drag, in: original)) }
            let last = moved ? drag : down
            let release = try XCTUnwrap(capture.release(in: original))
            XCTAssertEqual(release.input, last.released?.input)
            XCTAssertNotNil(release.input.pixelX)
            XCTAssertTrue(release.input.isValid)
            var encoded = Data()
            try EndpointBridgeInput.mouse(release.input).input().encode(to: &encoded)
            XCTAssertEqual(Array(encoded.prefix(4)), [2, 1, 0, 1])
            XCTAssertNil(capture.release(in: original))
        }
    }

    func testCaptureDropsPixelsWhenPixelGeometryOrModeChanges() throws {
        let original = try surface()
        let down = try XCTUnwrap(original.mouse(atColumn: 2.25, row: 2.25, kind: .down, button: .left))
        for changed in [try surface(pixelWidth: 80), try surface(pixelHeight: 160), try surface(pixels: false)] {
            var capture = EndpointMouseCapture(target: down, surface: original)
            let release = try XCTUnwrap(capture.release(in: changed))
            XCTAssertEqual(release.input.column, down.input.column)
            XCTAssertEqual(release.input.row, down.input.row)
            XCTAssertNil(release.input.pixelX)
            XCTAssertNil(release.input.pixelWidth)
            XCTAssertTrue(release.input.isValid)
        }
    }

    private func surface(reporting: Bool = true, pixelWidth: Int = 40, pixelHeight: Int = 80,
                         paneID: String = "w1:p1", width: Int = 4, height: Int = 4,
                         pixels: Bool = true) throws -> HerdrEndpointSurface {
        let cell: [String: Any] = ["symbol": " ", "foreground": 0, "background": 0, "modifiers": 0, "skip": false]
        let rect: [String: Any] = ["x": 1, "y": 1, "width": width, "height": height]
        let pane: [String: Any] = ["paneID": paneID, "contentRevision": 1, "rect": rect, "innerRect": rect,
            "focused": true, "mouseReporting": reporting, "pixelMouse": pixels, "alternateScreen": false,
            "pixelWidth": pixelWidth, "pixelHeight": pixelHeight]
        let value: [String: Any] = ["bootID": "mouse-test", "projectionRevision": 1, "revision": 1,
            "grid": ["width": 10, "height": 6, "cells": Array(repeating: cell, count: 60), "hyperlinks": []],
            "panes": [pane], "splits": [], "graphics": ["assets": [], "placements": [], "retained": []]]
        return try JSONDecoder().decode(HerdrEndpointSurface.self, from: JSONSerialization.data(withJSONObject: value))
    }
}
