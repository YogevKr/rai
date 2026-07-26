import Combine
import Foundation
import RaiCore

/// Observable state for the Codex Micro integration, shared between the
/// controller (which owns the hardware) and Settings (which displays it and
/// toggles it).
///
/// The enabled flag is the single source of truth and is persisted under
/// `MicroController.enabledDefaultsKey`, so a toggle in Settings takes effect
/// immediately AND survives relaunch — the integration previously only read
/// that key once at launch.
@MainActor
final class MicroStatusCenter: ObservableObject {
    static let shared = MicroStatusCenter()

    @Published var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            UserDefaults.standard.set(isEnabled, forKey: MicroController.enabledDefaultsKey)
            if !isEnabled { reset() }
        }
    }

    /// True only while a device is actually attached, not merely enabled.
    @Published private(set) var isConnected = false
    /// "USB" / "Bluetooth Low Energy" once attached.
    @Published private(set) var transportName: String?
    /// IOKit registry id of the selected node, useful when BLE publishes several.
    @Published private(set) var nodeID: UInt64?
    /// Last failure worth showing, e.g. the device being seized by Karabiner.
    @Published private(set) var lastError: String?
    /// Rolling count of accepted lighting writes — cheap proof the link is live.
    @Published private(set) var acknowledgedWrites = 0

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: MicroController.enabledDefaultsKey)
    }

    func deviceAttached(identity: MicroDeviceIdentity?) {
        isConnected = true
        lastError = nil
        transportName = identity?.transport.displayName
        nodeID = identity?.registryEntryID
    }

    func deviceDetached() {
        isConnected = false
        transportName = nil
        nodeID = nil
    }

    func recordAcknowledgedWrite() {
        acknowledgedWrites += 1
    }

    func recordError(_ message: String) {
        lastError = message
    }

    private func reset() {
        isConnected = false
        transportName = nil
        nodeID = nil
        lastError = nil
        acknowledgedWrites = 0
    }
}
