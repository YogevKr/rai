import XCTest
@testable import RaiApp

final class KeyRoutingDecisionTests: XCTestCase {
    func testRoutesOnlyForKeyWindowOwningTheTerminal() {
        XCTAssertTrue(KeyRoutingDecision.shouldRouteToTerminal(
            eventWindowIsKey: true, terminalIsInEventWindow: true,
            palettePresented: false, renamePresented: false
        ))
    }

    func testNeverRoutesEventsAimedAtAnotherWindow() {
        // A Settings-window keystroke must not reach a terminal in main.
        XCTAssertFalse(KeyRoutingDecision.shouldRouteToTerminal(
            eventWindowIsKey: true, terminalIsInEventWindow: false,
            palettePresented: false, renamePresented: false
        ))
    }

    func testNeverRoutesFromANonKeyWindow() {
        XCTAssertFalse(KeyRoutingDecision.shouldRouteToTerminal(
            eventWindowIsKey: false, terminalIsInEventWindow: true,
            palettePresented: false, renamePresented: false
        ))
    }

    func testTransientSurfacesBlockRouting() {
        XCTAssertFalse(KeyRoutingDecision.shouldRouteToTerminal(
            eventWindowIsKey: true, terminalIsInEventWindow: true,
            palettePresented: true, renamePresented: false
        ))
        XCTAssertFalse(KeyRoutingDecision.shouldRouteToTerminal(
            eventWindowIsKey: true, terminalIsInEventWindow: true,
            palettePresented: false, renamePresented: true
        ))
    }

    // MARK: pad-press suppression

    func testPadPressSuppressedWhenAuxiliaryWindowIsKey() {
        // Settings (or any window without the session terminal) is key.
        XCTAssertTrue(MicroControllerDecisions.shouldSuppressPadAction(
            bindingEditorActive: false, palettePresented: false,
            renamePresented: false, keyWindowHostsTerminal: false
        ))
    }

    func testPadPressAllowedFromBackgroundOrMainWindow() {
        // rai in the background: no key window at all — the pad's whole point.
        XCTAssertFalse(MicroControllerDecisions.shouldSuppressPadAction(
            bindingEditorActive: false, palettePresented: false,
            renamePresented: false, keyWindowHostsTerminal: nil
        ))
        // Main window key (hosts the terminal panes).
        XCTAssertFalse(MicroControllerDecisions.shouldSuppressPadAction(
            bindingEditorActive: false, palettePresented: false,
            renamePresented: false, keyWindowHostsTerminal: true
        ))
    }

    func testPadPressSuppressedByTransientSurfaces() {
        XCTAssertTrue(MicroControllerDecisions.shouldSuppressPadAction(
            bindingEditorActive: true, palettePresented: false,
            renamePresented: false, keyWindowHostsTerminal: true
        ))
        XCTAssertTrue(MicroControllerDecisions.shouldSuppressPadAction(
            bindingEditorActive: false, palettePresented: true,
            renamePresented: false, keyWindowHostsTerminal: true
        ))
        XCTAssertTrue(MicroControllerDecisions.shouldSuppressPadAction(
            bindingEditorActive: false, palettePresented: false,
            renamePresented: true, keyWindowHostsTerminal: true
        ))
    }

    /// macOS fires a menu key equivalent for every auto-repeat keyDown, so a
    /// held ⌘W walks the herd closing tab after tab — and for a one-tab space
    /// each close takes the whole space. One press, one close.
    func testRepeatedCommandWIsDropped() {
        XCTAssertTrue(
            KeyRoutingDecision.isRepeatedCloseShortcut(
                isARepeat: true, command: true, option: false,
                control: false, shift: false,
                charactersIgnoringModifiers: "w"
            )
        )
        // ⌘⇧W (close pane) arrives uppercased and is just as destructive.
        XCTAssertTrue(
            KeyRoutingDecision.isRepeatedCloseShortcut(
                isARepeat: true, command: true, option: false,
                control: false, shift: true,
                charactersIgnoringModifiers: "W"
            )
        )
    }

    func testFirstCommandWPressIsAllowedThrough() {
        XCTAssertFalse(
            KeyRoutingDecision.isRepeatedCloseShortcut(
                isARepeat: false, command: true, option: false,
                control: false, shift: false,
                charactersIgnoringModifiers: "w"
            )
        )
    }

    /// The guard is scoped to the close chord: held repeats of anything else
    /// (⌘1 tab switching, a bare "w" typed into a pane) must pass untouched.
    func testOtherRepeatedKeysArePassedThrough() {
        XCTAssertFalse(
            KeyRoutingDecision.isRepeatedCloseShortcut(
                isARepeat: true, command: false, option: false,
                control: false, shift: false,
                charactersIgnoringModifiers: "w"
            )
        )
        XCTAssertFalse(
            KeyRoutingDecision.isRepeatedCloseShortcut(
                isARepeat: true, command: true, option: false,
                control: false, shift: false,
                charactersIgnoringModifiers: "t"
            )
        )
        XCTAssertFalse(
            KeyRoutingDecision.isRepeatedCloseShortcut(
                isARepeat: true, command: true, option: false,
                control: false, shift: false,
                charactersIgnoringModifiers: nil
            )
        )
    }

    func testRepeatedCloseWithExtraModifiersIsPassedThrough() {
        XCTAssertFalse(
            KeyRoutingDecision.isRepeatedCloseShortcut(
                isARepeat: true, command: true, option: true,
                control: false, shift: false,
                charactersIgnoringModifiers: "w"
            )
        )
        XCTAssertFalse(
            KeyRoutingDecision.isRepeatedCloseShortcut(
                isARepeat: true, command: true, option: false,
                control: true, shift: true,
                charactersIgnoringModifiers: "W"
            )
        )
    }
}
