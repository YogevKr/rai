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

    let bindings: MicroBindings

    @Published var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            UserDefaults.standard.set(isEnabled, forKey: MicroController.enabledDefaultsKey)
            if !isEnabled { reset() }
        }
    }

    /// True while the visual pad is on screen, so identifying a physical
    /// control cannot also drive the live session underneath Settings.
    @Published var isBindingEditorActive = false

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
    /// Latest press edge from any bindable control. Releases are intentionally
    /// ignored so a learn operation cannot be completed twice by one gesture.
    @Published private(set) var lastPressedControl: MicroControl?
    @Published private(set) var pressSequence = 0
    private var bindingsObserver: AnyCancellable?

    private init() {
        bindings = MicroBindings.load()
        isEnabled = UserDefaults.standard.bool(forKey: MicroController.enabledDefaultsKey)
        // Settings remains usable while the hardware integration is disabled,
        // so persistence belongs here rather than in MicroController's lifetime.
        bindingsObserver = bindings.$table
            .dropFirst()
            .sink { [weak bindings] _ in bindings?.persist() }
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

    func recordPressed(_ control: MicroControl) {
        lastPressedControl = control
        pressSequence &+= 1
        let sequence = pressSequence
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard pressSequence == sequence else { return }
            lastPressedControl = nil
        }
    }

    private func reset() {
        isConnected = false
        transportName = nil
        nodeID = nil
        lastError = nil
        acknowledgedWrites = 0
        lastPressedControl = nil
        pressSequence = 0
    }
}
