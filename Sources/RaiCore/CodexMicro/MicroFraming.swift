import Foundation

public enum MicroChannel: UInt8, Sendable {
    case debugLog = 1
    case jsonRPC = 2
}

public enum MicroFrameOutput: Equatable, Sendable {
    case payload(String)
    case debugLog(String)
}

public enum MicroFramingError: Error, Equatable {
    case payloadTooLarge
    case invalidUTF8
}

public enum MicroFraming {
    public static let reportSize = 64
    public static let reportID: UInt8 = 0x06
    public static let maximumFragmentSize = 61

    public static func encode(
        _ payload: String,
        channel: MicroChannel = .jsonRPC
    ) throws -> [[UInt8]] {
        let bytes = Array(payload.utf8)
        guard bytes.count <= Int(UInt8.max) * maximumFragmentSize else {
            throw MicroFramingError.payloadTooLarge
        }

        // Matches WLDeviceComm.sendDataHID in @worklouder/wl-device-kit:
        // `while (offset < messageByteLength)` with MAX_CHUNK_SIZE 61. There is NO
        // trailing zero-length packet for exact multiples of 61 — the vendor sender
        // emits none, and messages are delimited by the payload's own newline.
        var chunks: [ArraySlice<UInt8>]
        if bytes.isEmpty {
            chunks = [bytes[bytes.startIndex..<bytes.endIndex]]
        } else {
            chunks = stride(from: 0, to: bytes.count, by: maximumFragmentSize).map {
                bytes[$0..<min($0 + maximumFragmentSize, bytes.count)]
            }
        }
        return chunks.map { chunk in
            var report = [UInt8](repeating: 0, count: reportSize)
            report[0] = reportID
            report[1] = channel.rawValue
            report[2] = UInt8(chunk.count)
            report.replaceSubrange(3..<(3 + chunk.count), with: chunk)
            return report
        }
    }
}

public struct MicroFrameDecoder: Sendable {
    /// Prefixes that mark the start of a fresh message. `{"m"` is what the
    /// hardware actually sends; `{"method"` is the documented-but-unobserved form.
    static let resyncSentinels: [[UInt8]] = [
        Array(#"{"m""#.utf8),
        Array(#"{"method""#.utf8),
    ]

    public let maximumBufferSize: Int
    private var buffers: [MicroChannel: [UInt8]] = [:]

    public init(maximumBufferSize: Int = 16 * 1024) {
        precondition(maximumBufferSize >= MicroFraming.maximumFragmentSize)
        self.maximumBufferSize = maximumBufferSize
    }

    public mutating func consume(_ report: [UInt8]) -> [MicroFrameOutput] {
        guard report.count == MicroFraming.reportSize,
              report[0] == MicroFraming.reportID,
              let channel = MicroChannel(rawValue: report[1]) else {
            return []
        }
        let length = Int(report[2])
        guard length <= MicroFraming.maximumFragmentSize, 3 + length <= report.count else {
            buffers[channel] = nil
            return []
        }
        let fragment = Array(report[3..<(3 + length)])
        // Resync sentinel. The firmware's real notifications start {"m": — the
        // {"method" form documented publicly never appears on device->host traffic,
        // so matching only that would silently disable recovery after a dropped
        // fragment. Accept both.
        if channel == .jsonRPC,
           Self.resyncSentinels.contains(where: { fragment.starts(with: $0) }),
           !(buffers[channel] ?? []).isEmpty {
            buffers[channel] = []
        }
        var buffer = buffers[channel] ?? []
        guard buffer.count + fragment.count <= maximumBufferSize else {
            buffers[channel] = nil
            return []
        }
        buffer.append(contentsOf: fragment)

        // Messages are NEWLINE-delimited, not length-delimited. The vendor
        // receiver (WLDeviceComm.parseHIDdata) accumulates per channel and
        // forwards complete newline-terminated lines. Fragment size says nothing
        // about whether a message ended: a 61-byte fragment can complete one and a
        // short fragment can leave one open. One report may also carry several
        // lines at once, so emit every complete line.
        var outputs: [MicroFrameOutput] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Array(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let string = String(bytes: line, encoding: .utf8) else { continue }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            switch channel {
            case .debugLog:
                outputs.append(.debugLog(trimmed))
            case .jsonRPC:
                guard let data = trimmed.data(using: .utf8),
                      (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                    continue
                }
                outputs.append(.payload(trimmed))
            }
        }
        buffers[channel] = buffer
        return outputs
    }
}
