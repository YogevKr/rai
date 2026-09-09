import SwiftUI
import UIKit
import XCTest
@testable import rai

@MainActor
final class EndpointAppearanceTests: XCTestCase {
    func testThemeSourceEditorPreservesTypedTOMLAndBindingUpdates() async throws {
        let state = ThemeSourceTestState()
        let host = UIHostingController(rootView: ThemeSourceTestHost(state: state))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        let editor = try await mountedThemeTextView(in: host, window: window)
        XCTAssertTrue(editor.becomeFirstResponder())
        XCTAssertEqual(editor.autocapitalizationType, .none)
        XCTAssertEqual(editor.autocorrectionType, .no)
        XCTAssertEqual(editor.spellCheckingType, .no)
        XCTAssertEqual(editor.smartQuotesType, .no)
        XCTAssertEqual(editor.smartDashesType, .no)
        XCTAssertEqual(editor.smartInsertDeleteType, .no)
        let toml = "[theme]\nname = \"default\"\npane_borders = false\n[theme.custom]\naccent = \"#00ff00\"\n# keep -- straight\n"
        for character in toml { editor.insertText(String(character)) }
        XCTAssertEqual(editor.text, toml)
        XCTAssertEqual(state.text, toml, "Native editing must update the SwiftUI binding without substitutions")

        editor.selectedRange = NSRange(location: 9, length: 4)
        state.objectWillChange.send()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(editor.selectedRange, NSRange(location: 9, length: 4), "An unchanged update must preserve selection")

        state.text = "x"
        for _ in 0..<100 {
            if editor.text == "x" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(editor.text, "x", "Programmatic changes must reach the editor")
        XCTAssertEqual(editor.selectedRange, NSRange(location: 1, length: 0), "Selection must remain within the changed text")
    }

    private func mountedThemeTextView(in host: UIViewController, window: UIWindow) async throws -> UITextView {
        for _ in 0..<100 {
            window.layoutIfNeeded()
            host.view.layoutIfNeeded()
            if let editor = themeTextView(in: host.view), editor.window === window { return editor }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try XCTUnwrap(nil as UITextView?, "The theme editor did not mount in the test window")
    }

    private func themeTextView(in view: UIView) -> UITextView? {
        var pending = [view]
        while let next = pending.popLast() {
            if let text = next as? UITextView { return text }
            pending.append(contentsOf: next.subviews)
        }
        return nil
    }

    func testSystemRestoresPresentingAppearanceAfterExplicitModes() async throws {
        let suite = "EndpointAppearanceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let connection = BridgeConnection(messageSender: { _ in })
        let host = UIHostingController(rootView: EndpointPhoneView(connection: connection, systemColorScheme: .light)
            .defaultAppStorage(defaults))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            connection.disconnect()
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        for (mode, expected) in [("light", UIUserInterfaceStyle.light), ("dark", .dark), ("system", .light)] {
            defaults.set(mode, forKey: "endpointAppearance")
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(host.traitCollection.userInterfaceStyle, expected, mode)
        }
    }
}

@MainActor
private final class ThemeSourceTestState: ObservableObject {
    @Published var text = ""
}

private struct ThemeSourceTestHost: View {
    @ObservedObject var state: ThemeSourceTestState
    var body: some View { EndpointThemeSourceEditor(text: $state.text) }
}
