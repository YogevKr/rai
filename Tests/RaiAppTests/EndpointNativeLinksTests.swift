import XCTest
import RaiCore
@testable import RaiApp

final class EndpointNativeLinksTests: XCTestCase {
    @MainActor
    func testPlainURLNeedsMatchingServerResultBeforeOpening() throws {
        let links = EndpointNativeLinks()
        let surface = try surface()
        var submitted: EndpointPluginRequest?
        XCTAssertTrue(links.activate(url: "https://example.com", column: 0, row: 0, surface: surface) {
            submitted = $0; return true
        })
        let request = try XCTUnwrap(submitted)
        let result = EndpointPluginResult(requestID: request.id, value: .object([
            "handled": .bool(false), "url": .string("https://example.com")]))
        XCTAssertEqual(links.receive(result, surface: surface)?.absoluteString, "https://example.com")
        XCTAssertNil(links.error)
        XCTAssertNil(links.receive(result, surface: surface))
    }

    @MainActor
    func testStaleOrMismatchedResultsNeverOpenBrowser() throws {
        for changed in [false, true] {
            let links = EndpointNativeLinks()
            var request: EndpointPluginRequest?
            links.activate(url: "https://example.com", column: 0, row: 0, surface: try surface()) {
                request = $0; return true
            }
            let result = EndpointPluginResult(requestID: try XCTUnwrap(request).id, value: .object([
                "handled": .bool(false), "url": .string(changed ? "https://example.com" : "https://other.example")]))
            XCTAssertNil(links.receive(result, surface: try surface(revision: changed ? 4 : 2)))
            XCTAssertNotNil(links.error)
        }
    }

    @MainActor
    func testHandledResultAndReconnectDoNotOpenBrowser() throws {
        let links = EndpointNativeLinks()
        let surface = try surface()
        var request: EndpointPluginRequest?
        let submit: (EndpointPluginRequest) -> Bool = { request = $0; return true }
        links.activate(url: "plugin://open", column: 0, row: 0, surface: surface, submit: submit)
        let handled = EndpointPluginResult(requestID: try XCTUnwrap(request).id, value: .object(["handled": .bool(true)]))
        XCTAssertNil(links.receive(handled, surface: surface))
        XCTAssertNil(links.error)
        links.activate(url: "https://example.com", column: 0, row: 0, surface: surface, submit: submit)
        let oldID = try XCTUnwrap(request).id
        links.reset()
        links.activate(url: "https://example.com", column: 0, row: 0, surface: surface, submit: submit)
        XCTAssertNotEqual(request?.id, oldID)
        XCTAssertNil(links.receive(.init(requestID: oldID, error: "old failure"), surface: surface))
        XCTAssertNil(links.error)
    }

    @MainActor
    func testPopupWebLinkNeverUsesThePanePluginAPIAndReportsBrowserFailure() throws {
        let links = EndpointNativeLinks()
        let surface = try popupSurface()
        links.activate(url: "https://example.com", column: 1, row: 1, surface: surface) { _ in
            XCTFail("Popup must not submit a pane plugin request"); return false
        }
        XCTAssertEqual(links.receivePopup(in: surface)?.absoluteString, "https://example.com")
        XCTAssertNil(links.receivePopup(in: surface))
        XCTAssertNil(links.error)
        links.browserFinished(accepted: false)
        XCTAssertEqual(links.error, "The browser could not open this link.")
    }

    @MainActor
    func testPopupCustomSchemeReportsUnsupportedRoutingWithoutSubmitting() throws {
        let links = EndpointNativeLinks()
        let surface = try popupSurface(url: "plugin://open")
        links.activate(url: "plugin://open", column: 1, row: 1, surface: surface) { _ in
            XCTFail("Popup custom scheme must not target a pane"); return true
        }
        XCTAssertNil(links.receivePopup(in: surface))
        XCTAssertTrue(try XCTUnwrap(links.error).contains("cannot route popup links to plugins"))
    }

    @MainActor
    func testPopupChangedBeforeOpeningNeverOpensTheBrowser() throws {
        for changed in [try popupSurface(terminal: "other"), try popupSurface(revision: 2), try surface()] {
            let links = EndpointNativeLinks()
            links.activate(url: "https://example.com", column: 1, row: 1, surface: try popupSurface()) { _ in false }
            XCTAssertNil(links.receivePopup(in: changed))
            XCTAssertNotNil(links.error)
        }
        let links = EndpointNativeLinks()
        links.activate(url: "https://example.com", column: 1, row: 1, surface: try popupSurface()) { _ in false }
        links.reset()
        XCTAssertNil(links.receivePopup(in: try popupSurface()))
    }

    private func popupSurface(terminal: String = "popup", revision: Int = 1,
                              url: String = "https://example.com") throws -> HerdrEndpointSurface {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(surface())) as? [String: Any])
        let cell: [String: Any] = ["symbol": "X", "foreground": 0, "background": 0, "modifiers": 0, "skip": false, "hyperlink": 0]
        value["revision"] = revision
        value["grid"] = ["width": 3, "height": 3, "cells": Array(repeating: cell, count: 9), "hyperlinks": []]
        value["popup"] = ["terminalID": terminal, "title": "Popup",
            "grid": ["width": 1, "height": 1, "cells": [cell], "hyperlinks": [url]],
            "mouseReporting": false, "pixelMouse": false, "pixelWidth": 0, "pixelHeight": 0]
        return try JSONDecoder().decode(HerdrEndpointSurface.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private func surface(revision: Int = 2) throws -> HerdrEndpointSurface {
        let rect: [String: Any] = ["x": 0, "y": 0, "width": 1, "height": 1]
        let cell: [String: Any] = ["symbol": "h", "foreground": 0, "background": 0, "modifiers": 0, "skip": false]
        let value: [String: Any] = ["bootID": "links", "projectionRevision": 1, "revision": 1,
            "grid": ["width": 1, "height": 1, "cells": [cell], "hyperlinks": []],
            "panes": [["paneID": "p", "contentRevision": revision, "rect": rect, "innerRect": rect,
                "focused": true, "mouseReporting": false, "pixelMouse": false, "alternateScreen": false,
                "pixelWidth": 0, "pixelHeight": 0]],
            "splits": [], "graphics": ["assets": [], "placements": [], "retained": []]]
        return try JSONDecoder().decode(HerdrEndpointSurface.self, from: JSONSerialization.data(withJSONObject: value))
    }
}
