import Foundation

/// Identity fields that travel from rai-microd to rai. A platform-neutral
/// subset of `MicroDeviceIdentity`, which is macOS-only.
public struct MicroHelperIdentity: Equatable, Sendable {
    public let vendorID: Int
    public let productID: Int
    public let manufacturer: String?
    public let product: String?
    /// Display name of the underlying link, e.g. "USB".
    public let transportName: String
    public let registryEntryID: UInt64

    public init(
        vendorID: Int,
        productID: Int,
        manufacturer: String?,
        product: String?,
        transportName: String,
        registryEntryID: UInt64
    ) {
        self.vendorID = vendorID
        self.productID = productID
        self.manufacturer = manufacturer
        self.product = product
        self.transportName = transportName
        self.registryEntryID = registryEntryID
    }
}

/// Newline-delimited JSON protocol between rai and the rai-microd privileged
/// helper. macOS 26.6 refuses raw HID access to keyboard-class devices for
/// non-root processes (input reports are withheld and SetReport fails with
/// kIOReturnNotPermitted, Input Monitoring notwithstanding), so a root helper
/// owns the pad link and bridges it over a uid-restricted unix socket.
///
/// Reports cross the wire as base64 of the full 64-byte report (ID 0x06
/// included). Both sides validate size and report ID; the helper additionally
/// refuses anything else, so a compromised client can at most drive this pad's
/// vendor channel — never another HID device.
public enum MicroHelperWire {
    public static let version = 1
    public static let defaultSocketPath = "/var/run/rai-microd.sock"
    /// Wire messages are ~120-byte frames; anything unterminated far beyond
    /// that is garbage, not a slow write. `UnixSocket`'s generic default
    /// (256 MiB, sized for herdr's scrollback RPCs) would let a wedged or
    /// compromised peer make either side buffer hundreds of megabytes before
    /// noticing — both ends of this protocol use this tight bound instead.
    public static let maxLineBytes = 16_384
    /// The installer writes this launchd job; its presence is the durable
    /// "helper is installed" signal (the socket file comes and goes with the
    /// daemon's lifecycle).
    public static let launchDaemonPlistPath =
        "/Library/LaunchDaemons/gr.krig.rai.microd.plist"
    /// The one description of how to (re)install the helper, interpolated
    /// into every user-facing remediation string — a stale copy of this path
    /// would surface exactly when things are already broken. Phrased for
    /// wherever Rai.app lives (/Applications or ~/Applications).
    public static let installCommandHint =
        "`sudo <path to Rai.app>/Contents/Resources/microd-install.sh` "
        + "(from a checkout: `sudo scripts/microd-install.sh`)"
    /// The "how to fix a broken helper" tail, shared by every remediation
    /// message so the three call sites cannot say three different things.
    public static let reinstallOrRemoveHint =
        "Reinstall the helper with \(installCommandHint), or remove it with "
        + "`sudo <path to Rai.app>/Contents/Resources/microd-install.sh --uninstall` "
        + "to use the direct HID link."

    /// Helper → rai.
    public enum ServerMessage: Equatable, Sendable {
        case hello(version: Int)
        case attached(MicroHelperIdentity)
        case detached
        case report([UInt8])
        /// A pad-side failure the user must see (pad seized by another
        /// process, SetReport refused). Without this, such failures live only
        /// in the daemon's root-owned log while Settings shows nothing.
        case error(String)
    }

    /// rai → helper.
    public enum ClientMessage: Equatable, Sendable {
        case send(report: [UInt8])
    }

    private struct Envelope: Codable {
        var t: String
        var v: Int?
        var d: String?
        var vendorID: Int?
        var productID: Int?
        var manufacturer: String?
        var product: String?
        var transport: String?
        var node: UInt64?
        var message: String?
    }

    // Stateless (no dates, no key strategy) — safe to share across threads
    // and calls. This sits on the per-HID-report and per-lighting-frame path
    // on both ends of the socket, so per-message construction is real waste.
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    public static func encode(_ message: ServerMessage) throws -> Data {
        let envelope: Envelope
        switch message {
        case .hello(let version):
            envelope = Envelope(t: "hello", v: version)
        case .attached(let identity):
            envelope = Envelope(
                t: "attached",
                vendorID: identity.vendorID,
                productID: identity.productID,
                manufacturer: identity.manufacturer,
                product: identity.product,
                transport: identity.transportName,
                node: identity.registryEntryID
            )
        case .detached:
            envelope = Envelope(t: "detached")
        case .report(let report):
            guard isValidReport(report) else { throw MicroFramingError.payloadTooLarge }
            envelope = Envelope(t: "report", d: Data(report).base64EncodedString())
        case .error(let message):
            envelope = Envelope(t: "error", message: message)
        }
        return try encoder.encode(envelope)
    }

    public static func encode(_ message: ClientMessage) throws -> Data {
        switch message {
        case .send(let report):
            guard isValidReport(report) else { throw MicroFramingError.payloadTooLarge }
            let envelope = Envelope(t: "send", d: Data(report).base64EncodedString())
            return try encoder.encode(envelope)
        }
    }

    /// nil means "drop this line": malformed JSON, a bad report, or a message
    /// type this side does not know (newer peers may add types).
    public static func decodeServerMessage(_ line: Data) -> ServerMessage? {
        guard let envelope = try? decoder.decode(Envelope.self, from: line) else {
            return nil
        }
        switch envelope.t {
        case "hello":
            guard let version = envelope.v else { return nil }
            return .hello(version: version)
        case "attached":
            guard let vendorID = envelope.vendorID,
                  let productID = envelope.productID,
                  let transport = envelope.transport,
                  let node = envelope.node else {
                return nil
            }
            return .attached(
                MicroHelperIdentity(
                    vendorID: vendorID,
                    productID: productID,
                    manufacturer: envelope.manufacturer,
                    product: envelope.product,
                    transportName: transport,
                    registryEntryID: node
                )
            )
        case "detached":
            return .detached
        case "report":
            guard let report = decodeReport(envelope.d) else { return nil }
            return .report(report)
        case "error":
            guard let message = envelope.message else { return nil }
            return .error(message)
        default:
            return nil
        }
    }

    /// One decode, one policy point. `.unknownType` is a structurally valid
    /// envelope this side does not understand — the documented version-bump-
    /// free evolution path, which servers must tolerate. `.malformed` is
    /// garbage (undecodable JSON, or a known type with a bad payload) and
    /// may count toward disconnecting the peer.
    public enum ClientLine: Equatable {
        case message(ClientMessage)
        case unknownType
        case malformed
    }

    public static func classifyClientLine(_ line: Data) -> ClientLine {
        guard let envelope = try? decoder.decode(Envelope.self, from: line) else {
            return .malformed
        }
        switch envelope.t {
        case "send":
            guard let report = decodeReport(envelope.d) else { return .malformed }
            return .message(.send(report: report))
        default:
            return .unknownType
        }
    }

    public static func isValidReport(_ report: [UInt8]) -> Bool {
        report.count == MicroFraming.reportSize && report.first == MicroFraming.reportID
    }


    private static func decodeReport(_ base64: String?) -> [UInt8]? {
        guard let base64, let data = Data(base64Encoded: base64) else { return nil }
        let report = Array(data)
        guard isValidReport(report) else { return nil }
        return report
    }
}
