import SwiftTerm
import SwiftUI
import UIKit
import XCTest
@testable import rai

final class TerminalTextSelectionTests: XCTestCase {
    func testLinksUsePhoneHandlersAndRejectRemoteFilesAndControlBytes() {
        for link in ["https://example.com/a?q=1", "http://localhost:3000", "mailto:a@example.com", "tel:+972528981820"] {
            XCTAssertNotNil(TerminalLink.url(link))
        }
        for link in ["/Users/mac/file", "file:///tmp/file", "javascript:alert(1)", "https:", "https://example.com/\n", "rai://pair"] {
            XCTAssertNil(TerminalLink.url(link))
        }
    }

    @MainActor
    func testTouchFindsImplicitAndExplicitLinksWithoutHover() {
        let terminal = EndpointPhoneTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        terminal.feed(text: "https://example.com\r\n\u{1b}]8;;https://example.org\u{1b}\\Label\u{1b}]8;;\u{1b}\\")
        let interaction = TerminalLinkInteraction(terminal: terminal)
        let size = terminal.getOptimalFrameSize()
        let cell = CGSize(width: size.width / CGFloat(terminal.getTerminal().cols),
                          height: size.height / CGFloat(terminal.getTerminal().rows))
        XCTAssertEqual(interaction.link(at: CGPoint(x: cell.width * 2, y: cell.height * 0.5)), "https://example.com")
        XCTAssertEqual(interaction.link(at: CGPoint(x: cell.width * 2, y: cell.height * 1.5)), "https://example.org")
        XCTAssertNil(interaction.link(at: CGPoint(x: -1, y: 0)))
        XCTAssertNil(interaction.link(at: CGPoint(x: cell.width * 2, y: cell.height * 3)))
    }

    @MainActor
    func testCapturedSelectionSurvivesOutputAndDoesNotSendInput() {
        let terminal = EndpointPhoneTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        var inputs = 0
        terminal.semanticInput = { _ in inputs += 1 }
        terminal.feed(text: "COPY THIS https://example.com\r\n")
        let snapshot = TerminalTextSnapshot(terminal: terminal)
        terminal.feed(text: "\u{1b}[2J\u{1b}[HREPLACED")
        XCTAssertTrue(snapshot.text.contains("COPY THIS https://example.com"))
        XCTAssertFalse(snapshot.text.contains("REPLACED"))
        XCTAssertEqual(inputs, 0)
    }
    @MainActor
    func testCapturedHardwareWordMotionCopiesWithoutSendingTerminalInput() throws {
        let terminal = EndpointPhoneTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        var inputs = 0
        terminal.semanticInput = { _ in inputs += 1 }
        terminal.feed(text: "first word\r\n")
        let snapshot = TerminalTextSnapshot(terminal: terminal)
        let view = EndpointSelectableTextView(frame: terminal.frame)
        view.text = snapshot.text
        view.isEditable = false
        view.isSelectable = true
        view.selectedRange = NSRange(location: 0, length: 0)
        var copied: String?
        view.clipboard = EndpointClipboard { copied = $0; return true }
        let command = try XCTUnwrap(view.keyCommands?.first {
            $0.input == UIKeyCommand.inputRightArrow && $0.modifierFlags == [.alternate, .shift]
        })
        XCTAssertTrue(command.wantsPriorityOverSystemBehavior)
        view.perform(command.action, with: command)
        view.copy(nil)
        XCTAssertEqual(copied, "first")
        XCTAssertEqual(inputs, 0)
        XCTAssertEqual(view.text, snapshot.text)
    }

    @MainActor
    func testUnmodifiedHardwareArrowsCollapseSelectionBeforeMoving() throws {
        let view = EndpointSelectableTextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        view.text = "first word"
        view.isEditable = false
        view.isSelectable = true
        for (input, expected) in [(UIKeyCommand.inputLeftArrow, 0), (UIKeyCommand.inputRightArrow, 5)] {
            view.selectedRange = NSRange(location: 0, length: 5)
            let command = try XCTUnwrap(view.keyCommands?.first { $0.input == input && $0.modifierFlags.isEmpty })
            view.perform(command.action, with: command)
            XCTAssertEqual(view.selectedRange, NSRange(location: expected, length: 0))
        }
        XCTAssertEqual(view.text, "first word")
    }

}

@MainActor
final class MountedSelectionControlsTests: XCTestCase {
    func testMountedExtendSwitchPersistsValueChanges() async throws {
        let controller = EndpointSelectionController()
        let host = UIHostingController(rootView: EndpointSelectionControls(controller: controller))
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
        for _ in 0..<100 {
            window.layoutIfNeeded()
            if descendants(of: host.view).contains(where: { $0 is UISwitch }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let toggle = try XCTUnwrap(descendants(of: host.view).compactMap { $0 as? UISwitch }.first)
        XCTAssertTrue(toggle.isOn)
        for expected in [false, true] {
            toggle.setOn(expected, animated: false)
            toggle.sendActions(for: .valueChanged)
            try await Task.sleep(for: .milliseconds(50))
            host.rootView = EndpointSelectionControls(controller: controller)
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            let rendered = try XCTUnwrap(descendants(of: host.view).compactMap { $0 as? UISwitch }.first)
            XCTAssertEqual(rendered.isOn, expected, "SwiftUI must preserve the changed binding after a root update")
        }
    }

    private func descendants(of root: UIView) -> [UIView] {
        var result = [root]
        var index = 0
        while index < result.count {
            result.append(contentsOf: result[index].subviews)
            index += 1
        }
        return result
    }

}
