import UIKit
import XCTest
@testable import rai

final class PromptDetectionTests: XCTestCase {
    func testDetectsNumberedPermissionPrompt() {
        let grid = """
        Claude wants to use Bash
        Do you want to allow this command?
        ❯ 1. Yes
          2. Yes, and don't ask again
          3. No, and tell Claude what to do differently
        Enter to select · Esc to cancel
        """

        let prompt = PromptDetector.detect(in: grid)

        XCTAssertEqual(
            prompt?.options,
            [
                PromptOption(digit: 1, label: "Yes"),
                PromptOption(digit: 2, label: "Yes, and don't ask again"),
                PromptOption(digit: 3, label: "No, and tell Claude what to do differently"),
            ]
        )
    }

    func testDetectsTrustPrompt() {
        let grid = """
        Do you trust the files in this folder?

        ❯ 1. Yes, proceed
          2. No, exit

        Enter to confirm · Esc to cancel
        """

        XCTAssertEqual(
            PromptDetector.detect(in: grid)?.options,
            [
                PromptOption(digit: 1, label: "Yes, proceed"),
                PromptOption(digit: 2, label: "No, exit"),
            ]
        )
    }

    func testDoesNotDetectOrdinaryNumberedOutput() {
        let grid = """
        Implementation plan:
        1. Add the model
        2. Add the view
        3. Run tests
        """

        XCTAssertNil(PromptDetector.detect(in: grid))
    }

    @MainActor
    func testLiveGridTextReadsCursorAddressedFramesWithoutLinefeeds() {
        // herdr's observe stream paints every cell by cursor address and never
        // sends a line feed or an alt-screen switch, and an agent pane's
        // history seed is empty. The grid must still be readable, or prompt
        // detection silently sees an empty screen (build 28 regression).
        let view = GridReadableTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        view.pinGridSize(cols: 80, rows: 8)
        let frame = "\u{1B}[H\u{1B}[2J"
            + "\u{1B}[1;1HDo you want to proceed?"
            + "\u{1B}[2;1H❯ 1. Yes"
            + "\u{1B}[3;1H  2. No"
            + "\u{1B}[4;1HEsc to cancel · Tab to amend"
        view.feed(byteArray: Array(frame.utf8)[...])

        let grid = view.liveGridText()

        XCTAssertTrue(grid.contains("1. Yes"), "grid was: \(grid)")
        XCTAssertEqual(
            PromptDetector.detect(in: grid)?.options.map(\.label),
            ["Yes", "No"]
        )
    }

    func testMovedScreenSignatureDoesNotMatch() throws {
        let original = """
        Allow Bash?
        1. Yes
        2. No
        Enter to select · Esc to cancel
        """
        let moved = """
        Build completed successfully.
        Ready for your next instruction.
        """
        let prompt = try XCTUnwrap(PromptDetector.detect(in: original))

        XCTAssertFalse(PromptDetector.signatureMatches(prompt, currentGridText: moved))
    }
}
