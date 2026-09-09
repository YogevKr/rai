import Foundation
import XCTest
@testable import RaiCore

final class EndpointGraphicsPolicyTests: XCTestCase {
    func testDisabledAndUnknownPoliciesRemoveImagesWithoutChangingCellsOrIdentity() throws {
        let keyObject: [String: Any] = ["source": ["pane": ["_0": "w1:p1", "_1": 1]],
            "width": 1, "height": 1, "format": 0, "byteCount": 3, "fingerprint": 1]
        let key = try JSONDecoder().decode(EndpointGraphicsKey.self, from: JSONSerialization.data(withJSONObject: keyObject))
        let placementObject: [String: Any] = ["asset": keyObject, "id": 1, "x": 0, "y": 0, "columns": 1, "rows": 1,
            "sourceX": 0, "sourceY": 0, "sourceWidth": 1, "sourceHeight": 1, "xOffset": 0, "yOffset": 0, "z": 0, "scrollbackOffset": 0]
        let placement = try JSONDecoder().decode(EndpointGraphicsPlacement.self, from: JSONSerialization.data(withJSONObject: placementObject))
        let grid = try JSONDecoder().decode(EndpointGrid.self, from: Data(#"{"width":1,"height":1,"cells":[{"symbol":"A","foreground":1,"background":0,"modifiers":0,"skip":false}],"hyperlinks":[]}"#.utf8))
        let surface = HerdrEndpointSurface(bootID: "boot", projectionRevision: 1, revision: 2, grid: grid, panes: [],
            splits: [], popup: nil, graphics: .init(assets: [.init(key: key, data: Data([255,0,0]))], placements: [placement], retained: [key]))
        XCTAssertEqual(EndpointGraphicsPolicy.enabled.apply(to: surface), surface)
        for policy in [EndpointGraphicsPolicy.disabled, .unknown("The server did not answer.")] {
            let filtered = policy.apply(to: surface)
            XCTAssertEqual(filtered.grid, grid)
            XCTAssertEqual(filtered.bootID, surface.bootID)
            XCTAssertEqual(filtered.revision, surface.revision)
            XCTAssertEqual(filtered.panes, surface.panes)
            XCTAssertTrue(filtered.graphics.assets.isEmpty)
            XCTAssertTrue(filtered.graphics.placements.isEmpty)
            XCTAssertTrue(filtered.graphics.retained.isEmpty)
        }
        XCTAssertNil(EndpointGraphicsPolicy.disabled.warning)
        XCTAssertNotNil(EndpointGraphicsPolicy.unknown("The server did not answer.").warning)
    }
}
