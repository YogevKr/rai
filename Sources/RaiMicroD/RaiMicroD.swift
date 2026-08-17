import Foundation
import RaiCore

/// rai-microd — privileged helper that owns the Codex Micro HID link.
///
/// macOS 26.6 refuses raw HID access to keyboard-class devices for non-root
/// processes: input reports are withheld and SetReport fails with
/// kIOReturnNotPermitted, Input Monitoring notwithstanding. This daemon runs
/// as root via launchd, owns the pad link, and bridges it to rai over a
/// uid-restricted unix socket speaking `MicroHelperWire`.
///
/// Installed by `scripts/microd-install.sh`.
@main
struct RaiMicroD {
    static func main() {
        // The client resolves the same constant, so the rendezvous path can
        // only be moved for both sides at once.
        var socketPath = MicroHelperWire.defaultSocketPath
        var allowedUID: uid_t?

        var arguments = CommandLine.arguments.dropFirst().makeIterator()
        while let argument = arguments.next() {
            switch argument {
            case "--socket":
                guard let value = arguments.next() else { usage() }
                socketPath = value
            case "--uid":
                guard let value = arguments.next(), let uid = uid_t(value) else { usage() }
                allowedUID = uid
            default:
                usage()
            }
        }
        guard let allowedUID else { usage() }
        // The installer already refuses to pass uid 0 (`SUDO_UID` check in
        // microd-install.sh), but that guard lives one caller away from the
        // invariant it protects. Enforced here too, at the source of truth,
        // so a hand-written launchd plist or a direct invocation can't
        // silently make root an accepted socket client — see the matching
        // comment on HelperServer's peer check.
        guard allowedUID != 0 else {
            FileHandle.standardError.write(
                Data("rai-microd: refusing --uid 0 (root); this daemon serves ONE non-root uid\n".utf8)
            )
            exit(64)
        }

        let server = HelperServer(socketPath: socketPath, allowedUID: allowedUID)
        do {
            try server.run()
        } catch {
            HelperServer.log("fatal: \(error.localizedDescription)")
            // Take the socket file down with us: rai treats its existence as
            // "helper installed" and would keep retrying a dead path.
            server.cleanup()
            exit(1)
        }
    }

    private static func usage() -> Never {
        FileHandle.standardError.write(
            Data("usage: rai-microd --uid <uid> [--socket <path>]\n".utf8)
        )
        exit(64)
    }
}
