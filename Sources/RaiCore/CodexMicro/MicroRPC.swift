import Foundation

public enum MicroInputEvent: Equatable, Sendable {
    case agentKey(index: Int, state: MicroPressState)
    case commandKey(id: String, state: MicroPressState)
    case encoder(MicroEncoderAction)
    /// Derived by `MicroJoystickTracker`, not decoded directly — the stick is
    /// analog and reports a continuous stream, not discrete press/release.
    case joystick(direction: MicroJoystickDirection, state: MicroPressState)
    /// A raw `v.oai.rad` sample: `angle` in normalized turns (0 = right,
    /// 0.25 = down, 0.5 = left, 0.75 = up), `distance` 0...1 from centre.
    case joystickSample(angle: Double, distance: Double)
    case deviceResponse(id: Int, result: JSONValue?, error: MicroRPCError?)
    case debugLog(String)
    case unknown(method: String?, payload: String)
}

public struct MicroRPCError: Codable, Equatable, Sendable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}

public struct MicroRPCRequest: Equatable, Sendable {
    public let id: Int
    public let payload: String

    public init(id: Int, payload: String) {
        self.id = id
        self.payload = payload
    }
}

public struct MicroRPCEncoder: Sendable {
    private var nextID: Int

    public init(startingAt: Int = 0) {
        precondition((0...999).contains(startingAt))
        nextID = startingAt
    }

    public mutating func request<Params: Encodable>(
        method: String,
        params: Params
    ) throws -> MicroRPCRequest {
        let id = nextID
        nextID = (nextID + 1) % 1000
        let envelope = RequestEnvelope(method: method, params: params, id: id)
        let data = try JSONEncoder().encode(envelope)
        guard let json = String(data: data, encoding: .utf8) else {
            throw MicroFramingError.invalidUTF8
        }
        return MicroRPCRequest(id: id, payload: json + "\n")
    }
}

public enum MicroRPCDecoder {
    public static func decode(_ output: MicroFrameOutput) -> MicroInputEvent {
        switch output {
        case .debugLog(let log):
            return .debugLog(log)
        case .payload(let payload):
            return decodePayload(payload)
        }
    }

    public static func decodePayload(_ payload: String) -> MicroInputEvent {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unknown(method: nil, payload: payload)
        }
        // The firmware emits the SHORT envelope on device->host notifications:
        // {"m":"v.oai.hid","p":{...}} — captured live from serial 441BF6D10968.
        // Published write-ups all describe {"method":…,"params":…}; accept both,
        // because host->device responses may still use the long form.
        let method = (object["method"] as? String) ?? (object["m"] as? String)
        let params = (object["params"] as? [String: Any]) ?? (object["p"] as? [String: Any])
        if method == "v.oai.hid",
           let params,
           let key = params["k"] as? String,
           let action = params["act"] as? Int {
            guard let semantic = MicroKeyMap.semantic(for: key, action: action) else {
                return .unknown(method: method, payload: payload)
            }
            switch semantic {
            case .agent(let index):
                return .agentKey(index: index, state: MicroPressState(rawValue: action)!)
            case .command(let id):
                return .commandKey(id: id, state: MicroPressState(rawValue: action)!)
            case .encoder(let encoder):
                return .encoder(encoder)
            }
        }
        // The stick streams continuous polar samples while it is off-centre
        // (captured: d = 0.12, 0.65, 0.75, 0.77, 0.80, 0.92, …) and never
        // reaches exactly 1.0. Treating a sample as a discrete press/release
        // produced duplicate presses and releases attributed to the wrong
        // direction, so decoding stays raw and edge detection lives in
        // MicroJoystickTracker.
        if method == "v.oai.rad",
           let params,
           let angle = params["a"] as? Double,
           let distance = params["d"] as? Double {
            return .joystickSample(angle: angle, distance: distance)
        }
        // Responses are identified by carrying `result`/`error`, NOT by lacking a
        // method: the firmware echoes the method name back on its replies, e.g.
        // {"result":{"ok":1},"id":0,"method":"v.oai.thstatus"} — observed live.
        // Requiring `method == nil` here classified every reply as .unknown.
        let isResponse = object["result"] != nil || object["error"] != nil
        if isResponse {
            let id = (object["id"] as? Int) ?? -1
            let result = object["result"].flatMap(JSONValue.init(any:))
            let error: MicroRPCError?
            if let value = object["error"] as? [String: Any],
               let code = value["code"] as? Int,
               let message = value["message"] as? String {
                error = MicroRPCError(code: code, message: message)
            } else {
                error = nil
            }
            return .deviceResponse(id: id, result: result, error: error)
        }
        return .unknown(method: method, payload: payload)
    }

}

private struct RequestEnvelope<Params: Encodable>: Encodable {
    let method: String
    let params: Params
    let id: Int
}

private extension JSONValue {
    init?(any: Any) {
        switch any {
        case is NSNull: self = .null
        case let value as Bool: self = .bool(value)
        case let value as String: self = .string(value)
        case let value as NSNumber: self = .number(value.doubleValue)
        case let value as [Any]:
            self = .array(value.compactMap(JSONValue.init(any:)))
        case let value as [String: Any]:
            self = .object(value.compactMapValues(JSONValue.init(any:)))
        default: return nil
        }
    }
}
