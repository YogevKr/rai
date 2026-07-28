/// The rule for the app-wide key monitor: when may a keystroke be routed to a
/// terminal pane? Split out (pure, no AppKit) so tests can pin the contract —
/// a local NSEvent monitor sees every window's key events, and any looseness
/// here types into the live session behind whatever the user is looking at.
enum KeyRoutingDecision {
    static func shouldRouteToTerminal(
        eventWindowIsKey: Bool,
        terminalIsInEventWindow: Bool,
        palettePresented: Bool,
        renamePresented: Bool
    ) -> Bool {
        eventWindowIsKey
            && terminalIsInEventWindow
            && !palettePresented
            && !renamePresented
    }
}
