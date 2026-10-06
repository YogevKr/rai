import AppKit

/// Maps palette key events before the search field can turn function keys into text.
enum PaletteKeyRouting {
    enum Action: Equatable {
        case move(Int)
        case activate
        case close
        case delete
        case type(String)
        case passThrough
    }

    static func action(
        keyCode: UInt16,
        characters: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> Action {
        // These are the normal macOS hardware key codes.
        switch keyCode {
        case 126: return .move(-1) // up
        case 125: return .move(1)  // down
        case 36, 76: return .activate
        case 53: return .close
        case 51: return .delete
        default: break
        }

        // Some keyboard and accessibility paths provide the function-key
        // scalar but no standard key code. Do not append these as text.
        let hasCommandLikeModifier = !modifiers.intersection([.command, .control, .option]).isEmpty
        if !hasCommandLikeModifier, let characters {
            switch characters {
            case "\u{F700}", "↑": return .move(-1)
            case "\u{F701}", "↓": return .move(1)
            default: break
            }
        }

        guard !hasCommandLikeModifier,
              let characters,
              !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({
                  $0.value >= 0x20 && $0.value != 0x7F
                      && !(0xF700...0xF8FF).contains($0.value)
              }) else {
            return .passThrough
        }
        return .type(characters)
    }
}
