import AppKit
import RaiCore

enum EndpointKeyboard {
    private static let specialKeys: [UInt16: EndpointKey.Special] = [
        51: .backspace, 36: .enter, 76: .enter, 123: .left, 124: .right, 126: .up, 125: .down,
        115: .home, 119: .end, 116: .pageUp, 121: .pageDown, 48: .tab, 117: .delete, 114: .insert, 53: .escape,
    ]
    private static let functionKeys: [UInt16: UInt8] = [
        122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8, 101: 9, 109: 10,
        103: 11, 111: 12, 105: 13, 107: 14, 113: 15, 106: 16, 64: 17, 79: 18, 80: 19, 90: 20,
    ]

    static func key(for event: NSEvent) -> EndpointKey? {
        let flags = event.modifierFlags
        var modifiers: UInt8 = 0
        if flags.contains(.shift) { modifiers |= 1 }
        if flags.contains(.control) { modifiers |= 2 }
        if flags.contains(.option) { modifiers |= 4 }
        if flags.contains(.command) { modifiers |= 8 }
        let code: EndpointKey.Code
        if let special = specialKeys[event.keyCode] {
            code = .special(special == .tab && flags.contains(.shift) ? .backTab : special)
        } else if let number = functionKeys[event.keyCode] {
            code = .function(number)
        } else if flags.contains(.control), let characters = event.charactersIgnoringModifiers,
                  characters.unicodeScalars.count == 1, let scalar = characters.unicodeScalars.first {
            code = .character(scalar)
        } else {
            // AppKit owns composed text and Option-based keyboard layouts.
            return nil
        }
        return EndpointKey(code: code, modifiers: modifiers, isRepeat: event.isARepeat)
    }
}
