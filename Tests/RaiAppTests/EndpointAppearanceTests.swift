import AppKit
import SwiftUI
import XCTest
@testable import RaiApp

@MainActor
final class EndpointAppearanceTests: XCTestCase {
    func testSystemRestoresApplicationAppearanceAfterExplicitModes() async throws {
        _ = NSApplication.shared
        let host = NSHostingController(rootView: Text("Appearance").modifier(EndpointMacAppearance(appearance: .system)))
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.orderFront(nil)
        let system = try XCTUnwrap(NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]))
        for (mode, expected) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua), ("system", system)] {
            host.rootView = Text("Appearance").modifier(EndpointMacAppearance(appearance: try XCTUnwrap(.init(rawValue: mode))))
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(host.view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), expected, mode)
        }
    }
}
