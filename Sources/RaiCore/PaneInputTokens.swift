import Foundation

public enum PaneInputToken: Equatable, Sendable {
    case text(String)
    case keys([String])
}

/// Splits a raw input byte stream into text runs and herdr key names.
///
/// `pane.send_input`'s text path has paste semantics: control bytes are
/// inserted literally (a backspace renders as `^?`) and a trailing CR becomes
/// a pasted newline instead of a submit. Keys must go through herdr's key
/// path to act like keystrokes, so companion input — which arrives as raw
/// terminal bytes — is translated here before it reaches the daemon.
public enum PaneInputTokenizer {
    public static func tokenize(_ bytes: [UInt8]) -> [PaneInputToken] {
        var tokens: [PaneInputToken] = []
        var textRun: [UInt8] = []
        var keyRun: [String] = []

        func flushText() {
            guard !textRun.isEmpty else { return }
            tokens.append(.text(String(decoding: textRun, as: UTF8.self)))
            textRun.removeAll()
        }
        func flushKeys() {
            guard !keyRun.isEmpty else { return }
            tokens.append(.keys(keyRun))
            keyRun.removeAll()
        }
        func appendKey(_ name: String) {
            flushText()
            keyRun.append(name)
        }
        func appendText(_ run: [UInt8]) {
            flushKeys()
            textRun.append(contentsOf: run)
        }

        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case 0x0D, 0x0A:
                appendKey("enter")
            case 0x09:
                appendKey("tab")
            case 0x7F, 0x08:
                appendKey("backspace")
            case 0x1B:
                // Recognize the arrow CSIs; other escape sequences pass
                // through as text — raw-mode TUIs interpret them natively.
                if index + 2 < bytes.count, bytes[index + 1] == 0x5B,
                   let arrow = Self.arrows[bytes[index + 2]] {
                    appendKey(arrow)
                    index += 2
                } else if index == bytes.count - 1 {
                    appendKey("escape")
                } else {
                    let rest = Array(bytes[index...])
                    appendText(rest)
                    index = bytes.count
                    continue
                }
            case 0x01...0x1A:
                // C0 controls map to ctrl+letter (0x01 = ctrl+a … 0x1A =
                // ctrl+z); tab/enter were handled above.
                let letter = Character(UnicodeScalar(UInt8(0x60 + byte)))
                appendKey("ctrl+\(letter)")
            default:
                appendText([byte])
            }
            index += 1
        }
        flushText()
        flushKeys()
        return tokens
    }

    private static let arrows: [UInt8: String] = [
        0x41: "up", 0x42: "down", 0x43: "right", 0x44: "left",
    ]
}
