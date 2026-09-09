import Foundation
import RaiCore

enum EndpointPhoneTestSurface {
    static func make(paneID: String = "w1:p1") throws -> HerdrEndpointSurface {
        let rect: [String: Any] = ["x": 0, "y": 0, "width": 1, "height": 1]
        let surfaceObject: [String: Any] = [
            "bootID": "boot", "projectionRevision": 1, "revision": 1,
            "grid": ["width": 1, "height": 1, "hyperlinks": [], "cells": [
                ["symbol": " ", "foreground": 0, "background": 0, "modifiers": 0, "skip": false]]],
            "panes": [["paneID": paneID, "contentRevision": 1, "rect": rect, "innerRect": rect,
                       "focused": true, "mouseReporting": false, "pixelMouse": false,
                       "scroll": ["offset": 0, "maximum": 100, "rows": 20],
                       "alternateScreen": false, "pixelWidth": 8, "pixelHeight": 16]],
            "splits": [], "graphics": ["assets": [], "placements": [], "retained": []],
        ]
        return try JSONDecoder().decode(HerdrEndpointSurface.self,
            from: JSONSerialization.data(withJSONObject: surfaceObject))
    }
}
