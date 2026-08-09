import RaiCore

/// The rule for the app-wide key monitor: when may a keystroke be routed to a
/// terminal pane? Split out (pure, no AppKit) so tests can pin the contract —
/// a local NSEvent monitor sees every window's key events, and any looseness
/// here types into the live session behind whatever the user is looking at.
enum KeyRoutingDecision {
    enum TerminalCommand: Equatable {
        case enterCopyMode
        case editScrollback
        case copyMode(CopyModeKey)
    }

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

    /// Whether a key event is an auto-repeat of a destructive close shortcut
    /// (⌘W closes the tab, ⌘⇧W the pane) and must be dropped.
    ///
    /// macOS delivers held key equivalents as repeated keyDowns, and AppKit
    /// fires the matching menu item for every one — holding ⌘W walks the herd
    /// closing tab after tab, exactly as holding ⌘W walks Safari's. A tab close
    /// is not recoverable in one keystroke, and for a one-tab space it takes the
    /// whole space, so no held-key behaviour is worth keeping here: one press,
    /// one close.
    static func isRepeatedCloseShortcut(
        isARepeat: Bool,
        command: Bool,
        option: Bool,
        control: Bool,
        shift _: Bool,
        charactersIgnoringModifiers: String?
    ) -> Bool {
        guard isARepeat, command, !option, !control else { return false }
        // ⇧ is folded in by lowercasing: ⌘⇧W arrives as "W".
        return charactersIgnoringModifiers?.lowercased() == "w"
    }

    /// Converts an AppKit key event into a pane-local command.
    static func terminalCommand(
        keyCode: UInt16,
        characters: String?,
        charactersIgnoringModifiers: String?,
        command: Bool,
        option: Bool,
        control: Bool,
        shift: Bool,
        copyModeActive: Bool
    ) -> TerminalCommand? {
        if !copyModeActive, command, shift, !option, !control {
            switch charactersIgnoringModifiers?.lowercased() {
            case "c": return .enterCopyMode
            case "e": return .editScrollback
            default: return nil
            }
        }
        guard copyModeActive else { return nil }
        guard !command, !option else { return nil }

        let key: CopyModeKey
        switch keyCode {
        case 53: key = .escape
        case 36, 76: key = .enter
        case 51: key = .backspace
        case 123: key = .left
        case 124: key = .right
        case 125: key = .down
        case 126: key = .up
        case 116: key = .pageUp
        case 121: key = .pageDown
        case 115: key = .home
        case 119: key = .end
        default:
            if control, !command, !option,
               let character = charactersIgnoringModifiers?.lowercased().first {
                key = .controlCharacter(character)
            } else if !command, !option, !control,
                      let characters, !characters.isEmpty,
                      characters.unicodeScalars.allSatisfy({
                          $0.value >= 0x20 && $0.value != 0x7F
                      }) {
                key = .character(characters)
            } else {
                key = .ignored
            }
        }
        return .copyMode(key)
    }
}
