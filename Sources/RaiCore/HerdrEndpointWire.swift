import Foundation

public enum HerdrEndpointError: LocalizedError, Equatable {
    case malformed
    case incompatible(String)
    case limitExceeded
    case staleIdentity
    case busy
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .malformed: "Herdr returned an invalid endpoint message."
        case .incompatible(let reason): "The Herdr endpoint is incompatible: \(reason)"
        case .limitExceeded: "The Herdr endpoint exceeded a transport limit."
        case .staleIdentity: "The Herdr endpoint identity changed. Reconnect before sending another action."
        case .busy: "The Herdr endpoint is processing another request."
        case .timedOut: "The Herdr endpoint timed out. An action may have completed; check before retrying."
        }
    }
}

/// Generation-one tags are frozen independently of Herdr's private protocol version.
enum HerdrEndpointWire {
    static let maximumFrameBytes = 2 * 1024 * 1024

    enum Message: Equatable {
        case control(kind: String, data: String)
        case notification(EndpointNotification)
        case windowTitle(String?)
        case response(bootID: String, requestID: String, final: Bool, data: Data)
        case shutdown
        case other(tag: UInt64, payload: Data)
    }

    static func control(kind: String, data: String) -> Data {
        var result = Data([20])
        appendString(kind, to: &result)
        appendString(data, to: &result)
        return result
    }

    static func request(bootID: String, json: String) -> Data {
        var result = Data([15])
        appendString(bootID, to: &result)
        appendString(json, to: &result)
        return result
    }

    static func appendInteger(_ value: UInt64, to data: inout Data) {
        if value < 251 { data.append(UInt8(value)); return }
        let width = value <= UInt16.max ? 2 : (value <= UInt32.max ? 4 : 8)
        data.append(width == 2 ? 251 : (width == 4 ? 252 : 253))
        for byte in 0..<width { data.append(UInt8(truncatingIfNeeded: value >> (byte * 8))) }
    }

    static func appendString(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        appendInteger(UInt64(bytes.count), to: &data)
        data.append(bytes)
    }

    static func decode(_ data: Data) throws -> Message {
        guard data.count <= maximumFrameBytes else { throw HerdrEndpointError.limitExceeded }
        var reader = EndpointBinaryReader(data: data)
        let tag = try reader.integer()
        let message: Message
        switch tag {
        case 6:
            let title = try reader.optional { try $0.string() }
            if let title {
                guard title.utf8.count <= 4096,
                      !title.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }) else {
                    throw HerdrEndpointError.malformed
                }
            }
            message = .windowTitle(title)
        case 14: message = .notification(try EndpointNotification.decodeSemantic(&reader))
        case 15: message = .notification(.init(kind: .error, title: try reader.string()))
        case 20: message = .control(kind: try reader.string(), data: try reader.string())
        case 18:
            message = .response(bootID: try reader.string(), requestID: try reader.string(),
                                final: try reader.boolean(), data: try reader.bytes())
        case 3: return .shutdown
        default: return .other(tag: tag, payload: data)
        }
        guard reader.isAtEnd else { throw HerdrEndpointError.malformed }
        return message
    }
}

struct EndpointBinaryReader {
    let data: Data
    private var offset = 0

    init(data: Data) { self.data = Data(data) }
    var isAtEnd: Bool { offset == data.count }

    mutating func byte() throws -> UInt8 {
        guard offset < data.count else { throw HerdrEndpointError.malformed }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    mutating func integer() throws -> UInt64 {
        let prefix = try byte()
        if prefix < 251 { return UInt64(prefix) }
        let width: Int
        switch prefix {
        case 251: width = 2
        case 252: width = 4
        case 253: width = 8
        default: throw HerdrEndpointError.malformed
        }
        var result: UInt64 = 0
        for index in 0..<width { result |= UInt64(try byte()) << (index * 8) }
        return result
    }

    mutating func boolean() throws -> Bool {
        switch try byte() {
        case 0: false
        case 1: true
        default: throw HerdrEndpointError.malformed
        }
    }

    mutating func bytes() throws -> Data {
        let length = try integer()
        guard length <= data.count - offset else { throw HerdrEndpointError.malformed }
        let start = data.startIndex + offset
        offset += Int(length)
        return Data(data[start..<(start + Int(length))])
    }

    mutating func string() throws -> String {
        guard let value = String(data: try bytes(), encoding: .utf8) else { throw HerdrEndpointError.malformed }
        return value
    }

    mutating func unsigned<T: FixedWidthInteger & UnsignedInteger>(_ type: T.Type) throws -> T {
        guard let value = T(exactly: try integer()) else { throw HerdrEndpointError.malformed }
        return value
    }

    mutating func optional<T>(_ decode: (inout Self) throws -> T) throws -> T? {
        try boolean() ? decode(&self) : nil
    }

    mutating func array<T>(limit: Int = 65_536, _ decode: (inout Self) throws -> T) throws -> [T] {
        let count = try integer()
        guard count <= limit, count <= data.count - offset else { throw HerdrEndpointError.limitExceeded }
        return try (0..<Int(count)).map { _ in try decode(&self) }
    }
}
