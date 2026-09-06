import Network

public enum BridgeWebSocketPolicy {
    public enum Action: Equatable {
        case text, ignore, close, reject
    }

    public static func action(for opcode: NWProtocolWebSocket.Opcode?) -> Action {
        switch opcode {
        case .text: return .text
        // autoReplyPing sends the pong, but Network still delivers the control frame.
        case .ping, .pong: return .ignore
        case .close: return .close
        default: return .reject
        }
    }
}
