import Foundation
import RaiCore

enum EndpointPhoneTestSurface {
    static func make(paneID: String = "w1:p1", mouseReporting: Bool = false,
                     popupMouseReporting: Bool = false, alternateScreen: Bool = false,
                     columns: Int = 1, rows: Int = 1) throws -> HerdrEndpointSurface {
        let width = popupMouseReporting ? 5 : columns
        let height = popupMouseReporting ? 5 : rows
        let rect: [String: Any] = ["x": 0, "y": 0, "width": width, "height": height]
        let cell: [String: Any] = ["symbol": " ", "foreground": 0, "background": 0, "modifiers": 0, "skip": false]
        let popup: [String: Any]? = popupMouseReporting ? [
            "terminalID": "popup", "title": "Popup", "width": ["cells": ["_0": 3]],
            "height": ["cells": ["_0": 3]],
            "grid": ["width": 3, "height": 3, "hyperlinks": [], "cells": Array(repeating: cell, count: 9)],
            "mouseReporting": true, "pixelMouse": false, "pixelWidth": 8, "pixelHeight": 16,
        ] : nil
        var surfaceObject: [String: Any] = [
            "bootID": "boot", "projectionRevision": 1, "revision": 1,
            "grid": ["width": width, "height": height, "hyperlinks": [],
                     "cells": Array(repeating: cell, count: width * height)],
            "panes": [["paneID": paneID, "contentRevision": 1, "rect": rect, "innerRect": rect,
                       "focused": true, "mouseReporting": mouseReporting, "pixelMouse": false,
                       "scroll": ["offset": 0, "maximum": 100, "rows": 20],
                       "alternateScreen": alternateScreen, "pixelWidth": 8, "pixelHeight": 16]],
            "splits": [], "graphics": ["assets": [], "placements": [], "retained": []],
        ]
        if let popup { surfaceObject["popup"] = popup }
        return try JSONDecoder().decode(HerdrEndpointSurface.self,
            from: JSONSerialization.data(withJSONObject: surfaceObject))
    }
}
