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
}
