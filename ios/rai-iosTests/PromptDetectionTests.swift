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
