import Foundation
import XCTest
@testable import RaiCore

final class EndpointGraphicsTests: XCTestCase {
    private func asset(_ id: UInt32 = 1, data: Data = Data([255, 0, 0]), width: UInt32 = 1,
                       height: UInt32 = 1, format: UInt64 = 0) throws -> EndpointGraphicsScene.Asset {
        let object: [String: Any] = ["source": ["pane": ["_0": "w1:p1", "_1": id]],
            "width": width, "height": height, "format": format, "byteCount": data.count, "fingerprint": id]
        let key = try JSONDecoder().decode(EndpointGraphicsKey.self, from: JSONSerialization.data(withJSONObject: object))
        return .init(key: key, data: data)
    }

    private func placement(_ asset: EndpointGraphicsScene.Asset, x: Int = 1) throws -> EndpointGraphicsPlacement {
        let key = try JSONSerialization.jsonObject(with: JSONEncoder().encode(asset.key))
        let object: [String: Any] = ["asset": key, "id": 1, "x": x, "y": 1, "columns": 2, "rows": 2,
            "sourceX": 0, "sourceY": 0, "sourceWidth": asset.key.width, "sourceHeight": asset.key.height,
            "xOffset": 0, "yOffset": 0, "z": 0, "scrollbackOffset": 0]
        return try JSONDecoder().decode(EndpointGraphicsPlacement.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func grid() throws -> EndpointGrid {
        let cell: [String: Any] = ["symbol": " ", "foreground": 0, "background": 0, "modifiers": 0, "skip": false]
        return try JSONDecoder().decode(EndpointGrid.self, from: JSONSerialization.data(withJSONObject:
            ["width": 4, "height": 4, "cells": Array(repeating: cell, count: 16), "hyperlinks": []]))
    }

    func testDeliveryCachePreservesMissingUploadsAndRetiresDeletedImages() throws {
        let image = try asset()
        let placements = try [placement(image)]
        var cache = EndpointGraphicsCache()
        let initial = cache.resolve(.init(assets: [image], placements: placements, retained: []))
        let delta = initial.excludingAssets(Set(initial.assets.map(\.key)))
        XCTAssertTrue(delta.assets.isEmpty, "Text updates must not repeat image bytes on the phone bridge")
        let retained = cache.resolve(delta)
        XCTAssertEqual(initial.assets, retained.assets)
        XCTAssertEqual(retained.placements, placements)
        XCTAssertTrue(cache.resolve(.init(assets: [], placements: [], retained: [])).assets.isEmpty)
        XCTAssertTrue(cache.resolve(.init(assets: [], placements: placements, retained: [])).assets.isEmpty)
    }

    func testOversizedImageDoesNotSuppressSmallNeighbor() throws {
        let large = try asset(2, data: Data(repeating: 0, count: EndpointGraphicsCache.maximumBytes + 1))
        let small = try asset()
        var cache = EndpointGraphicsCache()
        let scene = cache.resolve(.init(assets: [large, small], placements: try [placement(large), placement(small)], retained: []))
        XCTAssertEqual(scene.assets, [small])
        XCTAssertEqual(scene.placements.count, 2)
    }

    func testEncoderRetainsUploadsReplacesPlacementsAndClearsOnReset() throws {
        let image = try asset()
        let scene = EndpointGraphicsScene(assets: [image], placements: try [placement(image)], retained: [])
        var encoder = EndpointGraphicsEncoder()
        let first = String(decoding: encoder.render(scene, grid: try grid()), as: UTF8.self)
        XCTAssertTrue(first.contains("a=t,f=32,s=1,v=1,i=1,q=2,m=0;/wAA/w=="))
        XCTAssertTrue(first.contains("\u{1b}[2;2H"))
        XCTAssertTrue(first.contains("a=p,i=1,p=1,q=2,C=1,c=2,r=2"))
        XCTAssertTrue(first.hasSuffix("\u{1b}8"), "Graphics must restore the terminal cursor")
        let second = String(decoding: encoder.render(scene, grid: try grid()), as: UTF8.self)
        XCTAssertFalse(second.contains("a=t"))
        XCTAssertTrue(second.contains("a=p"))
        let reset = String(decoding: encoder.render(scene, grid: try grid(), reset: true), as: UTF8.self)
        XCTAssertTrue(reset.contains("a=d,d=A,q=2"))
        XCTAssertTrue(reset.contains("a=t"))
        let deleted = String(decoding: encoder.render(.init(assets: [], placements: [], retained: []), grid: try grid()), as: UTF8.self)
        XCTAssertTrue(deleted.contains("a=d,d=A,q=2"))
    }

    func testDecoderRejectsFalseDimensionsAndMalformedData() throws {
        XCTAssertEqual(EndpointGraphicsEncoder.pixels(try asset()), Data([255, 0, 0, 255]))
        XCTAssertNil(EndpointGraphicsEncoder.pixels(try asset(width: 2)))
        XCTAssertNil(EndpointGraphicsEncoder.pixels(try asset(data: Data("invalid PNG".utf8), format: 2)))
        XCTAssertNil(EndpointGraphicsEncoder.pixels(try asset(width: UInt32.max, height: UInt32.max)))
    }

    func testPlacementCannotEscapeTheGrid() throws {
        let image = try asset()
        var encoder = EndpointGraphicsEncoder()
        let output = String(decoding: encoder.render(.init(assets: [image], placements: try [placement(image, x: 4)], retained: []),
            grid: try grid()), as: UTF8.self)
        XCTAssertFalse(output.contains("a=p"))
        XCTAssertEqual(encoder.omittedImages, 1)
    }

    func testPopupImagesRenderAtTheirResolvedOrigin() throws {
        let original = try asset()
        var key = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original.key)) as? [String: Any])
        key["source"] = ["popup": ["_0": "popup-terminal", "_1": 1]]
        let popupKey = try JSONDecoder().decode(EndpointGraphicsKey.self, from: JSONSerialization.data(withJSONObject: key))
        let image = EndpointGraphicsScene.Asset(key: popupKey, data: original.data)
        let placed = EndpointGraphicsPlacement(translating: try placement(image), x: 1, y: 1)
        var encoder = EndpointGraphicsEncoder()
        let bytes = encoder.render(.init(assets: [image], placements: [placed], retained: []), grid: try grid())
        let output = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(output.contains("\u{1b}[3;3H"))
        XCTAssertTrue(output.contains("a=p,i=1"))
        XCTAssertEqual(encoder.omittedImages, 0)
    }
}
