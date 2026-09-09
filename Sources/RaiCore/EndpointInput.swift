import Foundation

public struct EndpointKey: Sendable, Equatable {
    public enum Special: UInt8, Codable, Sendable {
        case backspace, enter, left, right, up, down, home, end, pageUp, pageDown
        case tab, backTab, delete, insert, escape
    }

    public enum Code: Sendable, Equatable {
        case special(Special), character(Unicode.Scalar), function(UInt8)
    }

    public let code: Code
    public let modifiers: UInt8
    public let isRepeat: Bool

    public init(code: Code, modifiers: UInt8 = 0, isRepeat: Bool = false) {
        self.code = code
        self.modifiers = modifiers
        self.isRepeat = isRepeat
    }

    func encode(to data: inout Data) {
        data.append(0) // ClientPaneInputEvent::Key
        switch code {
        case .special(let code): data.append(code.rawValue)
        case .character(let scalar):
            data.append(15)
            data.append(contentsOf: String(scalar).utf8) // Bincode char has no string length prefix.
        case .function(let number): data.append(contentsOf: [16, number])
        }
        data.append(contentsOf: [modifiers, isRepeat ? 1 : 0, 1, 0, 0, 0, 0, 0])
        // Repeat count 1; no shifted codepoint, generated text, release tracking, physical ID, or Windows record.
    }
}

public enum EndpointInput: Sendable, Equatable {
    case text(String), paste(String), key(EndpointKey)
    case mouse(EndpointMouse)

    public var byteCount: Int {
        switch self {
        case .text(let text), .paste(let text): return text.utf8.count + 16
        case .key: return 32
        case .mouse: return 96
        }
    }

    func encode(to data: inout Data) {
        switch self {
        case .text(let text):
            data.append(1)
            HerdrEndpointWire.appendString(text, to: &data)
        case .paste(let text):
            data.append(3)
            HerdrEndpointWire.appendString(text, to: &data)
        case .key(let key): key.encode(to: &data)
        case .mouse(let mouse): mouse.encode(to: &data)
        }
    }
}
