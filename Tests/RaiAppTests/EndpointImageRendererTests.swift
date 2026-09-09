#if os(macOS)
import AppKit
#else
import UIKit
#endif
import RaiCore
@testable import SwiftTerm
import XCTest

@MainActor
final class EndpointImageRendererTests: XCTestCase {
    private func scene(green: Bool) throws -> EndpointGraphicsScene {
        var assets: [[String: Any]] = []
        var placements: [[String: Any]] = []
        for id in 1...2 {
            let color: [UInt8] = id == 2 ? [0, 0, 255] : (green ? [0, 255, 0] : [255, 0, 0])
            let key: [String: Any] = ["source": ["pane": ["_0": "w1:p1", "_1": id]],
                "width": 1, "height": 1, "format": 0, "byteCount": 3, "fingerprint": id == 1 && green ? 3 : id]
            assets.append(["key": key, "data": Data(color).base64EncodedString()])
            placements.append(["asset": key, "id": 1, "x": id - 1, "y": 0, "columns": 1, "rows": 1,
                "sourceX": 0, "sourceY": 0, "sourceWidth": 1, "sourceHeight": 1,
                "xOffset": 0, "yOffset": 0, "z": 1, "scrollbackOffset": 0])
        }
        return try JSONDecoder().decode(EndpointGraphicsScene.self, from: JSONSerialization.data(withJSONObject:
            ["assets": assets, "placements": placements, "retained": []]))
    }

    private func grid() throws -> EndpointGrid {
        try JSONDecoder().decode(EndpointGrid.self, from: Data(#"{"width":2,"height":1,"cells":[{"symbol":" ","foreground":0,"background":0,"modifiers":0,"skip":false},{"symbol":" ","foreground":0,"background":0,"modifiers":0,"skip":false}],"hyperlinks":[]}"#.utf8))
    }

    func testIdlePolicyChangesRemoveAndRestoreImagesWithoutRepaintingUnchangedState() throws {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let surfaceData = try JSONSerialization.data(withJSONObject: [
            "bootID": "boot", "projectionRevision": 1, "revision": 2,
            "grid": JSONSerialization.jsonObject(with: JSONEncoder().encode(grid())), "panes": [], "splits": [],
            "graphics": JSONSerialization.jsonObject(with: JSONEncoder().encode(scene(green: false)))])
        let surface = try JSONDecoder().decode(HerdrEndpointSurface.self, from: surfaceData)
        var previous: EndpointSurfaceRenderKey?
        var encoder = EndpointGraphicsEncoder()
        let steps: [(EndpointGraphicsPolicy, Bool, Int)] = [
            (.enabled, true, 2), (.enabled, false, 2),
            (.disabled, true, 0), (.disabled, false, 0),
            (.unknown("Policy request failed"), false, 0),
            (.enabled, true, 2), (.enabled, false, 2)
        ]
        for (policy, needsRender, imageCount) in steps {
            let current = policy.apply(to: surface)
            let key = EndpointSurfaceRenderKey(current)
            XCTAssertEqual(current.revision, surface.revision)
            XCTAssertEqual(current.projectionRevision, surface.projectionRevision)
            XCTAssertEqual(previous != key, needsRender)
            if previous != key {
                view.feed(byteArray: Array(encoder.render(current.presentationGraphics, grid: current.presentationGrid))[...])
                previous = key
            }
            XCTAssertEqual(view.getTerminal().kittyGraphicsState.imagesById.count, imageCount)
            XCTAssertEqual(view.getTerminal().kittyGraphicsState.placementsByKey.count, imageCount)
        }
    }

    func testReplacingOneImagePreservesItsNeighborInSwiftTerm() throws {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let grid = try grid()
        var encoder = EndpointGraphicsEncoder()
        for green in [false, true, true] {
            let bytes = encoder.render(try scene(green: green), grid: grid)
            view.feed(byteArray: Array(bytes)[...])
            XCTAssertEqual(view.getTerminal().kittyGraphicsState.imagesById.count, 2)
            XCTAssertEqual(view.getTerminal().kittyGraphicsState.placementsByKey.count, 2,
                           "Replacement and repaint must preserve both image placements")
        }
    }

    func testFullTextRepaintRestoresImageDataAndPlacements() throws {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let grid = try grid()
        var encoder = EndpointGraphicsEncoder()
        let scene = try scene(green: false)
        view.feed(byteArray: Array(encoder.render(scene, grid: grid))[...])
        XCTAssertEqual(view.getTerminal().kittyGraphicsState.imagesById.count, 2)
        for _ in 0..<3 {
            view.feed(byteArray: Array(EndpointANSI.render(grid, previous: nil))[...])
            XCTAssertTrue(view.getTerminal().kittyGraphicsState.imagesById.isEmpty,
                          "A full text repaint invalidates cached terminal image data")
            view.feed(byteArray: Array(encoder.render(scene, grid: grid, reset: true))[...])
            XCTAssertEqual(view.getTerminal().kittyGraphicsState.imagesById.count, 2)
            XCTAssertEqual(view.getTerminal().kittyGraphicsState.placementsByKey.count, 2)
        }
    }
}
