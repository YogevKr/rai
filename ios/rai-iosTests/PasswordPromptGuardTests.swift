import XCTest
@testable import rai

final class PasswordPromptGuardTests: XCTestCase {
    func testRecognizesAnchoredPasswordPromptsOnLastNonemptyRow() {
        let prompts = [
            "output\n[sudo] password for yogev:   \n",
            "alice's password:",
            "Build User's password:",
            "Enter passphrase:",
            "Enter passphrase for key '/Users/y/.ssh/id_ed25519':",
            "Password:",
            "Passphrase:\n\n",
        ]

        for grid in prompts {
            XCTAssertTrue(PasswordPromptGuard.isPasswordPrompt(grid), grid)
        }
    }

    func testRejectsLooseOrQuotedMatches() {
        let screens = [
            "Agent quoted: Password:",
            "Password: use your token",
            "[sudo] password for:",
            "Enter passphrase for key",
            "Enter passphrase when prompted:",
            "Enter passphrase for key '/tmp/id':\n\n❯ Continue your message",
            "> Enter passphrase for key '/tmp/id':\nAgent response\n❯ ",
            "",
        ]

        for grid in screens {
            XCTAssertFalse(PasswordPromptGuard.isPasswordPrompt(grid), grid)
        }
    }

    func testRefusalMessageNamesDroppedOutboxLines() {
        XCTAssertEqual(
            PasswordPromptGuard.refusalMessage(droppedQueuedLines: 2),
            PasswordPromptGuard.refusal + " 2 queued lines for this pane were dropped."
        )
    }

    func testGridReaderPaintsFullANSIFrameAtNativeSize() throws {
        let reader = PasswordPromptGridReader()
        let text = try XCTUnwrap(reader.apply(
            data: Data("\u{1B}[Hbuild output\r\nPassword:\u{1B}[0m".utf8),
            full: true,
            size: PaneGridSize(cols: 80, rows: 4),
            paneID: "pane-a"
        ))

        XCTAssertTrue(PasswordPromptGuard.isPasswordPrompt(text))
    }

    func testGridReaderAppliesLaterFullReplacement() throws {
        let reader = PasswordPromptGridReader()
        _ = reader.apply(
            data: Data("\u{1B}[HPassword:".utf8),
            full: true,
            size: PaneGridSize(cols: 80, rows: 4),
            paneID: "pane-a"
        )

        let text = try XCTUnwrap(reader.apply(
            data: Data("\u{1B}[H> Enter passphrase:\r\n\r\n❯ Continue".utf8),
            full: true,
            size: PaneGridSize(cols: 80, rows: 4),
            paneID: "pane-a"
        ))

        XCTAssertFalse(PasswordPromptGuard.isPasswordPrompt(text))
    }

    func testRefusedSendKeepsDraftWhileAcceptedAndQueuedSendsClearIt() {
        XCTAssertTrue(ComposedLineDraftPolicy.shouldClear(after: .accepted))
        XCTAssertTrue(ComposedLineDraftPolicy.shouldClear(after: .queued))
        XCTAssertFalse(ComposedLineDraftPolicy.shouldClear(after: .refused))
    }
}
