import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var pairing: Pairing?
    @Published var pendingOpenPaneID: String?
    let connection = BridgeConnection()

    private let pairingStore = PairingStore()
    private var deviceToken: String?

    init() {
        connection.didConnect = { [weak self] in
            self?.registerPushIfPossible()
        }
        // Testing/automation affordance: pair straight from a launch env var,
        // e.g. `simctl launch --setenv RAI_PAIR_URL "rai://pair?..."`. Harmless
        // in normal use (the var is never set); lets e2e tests skip the QR/UI.
        if let urlString = ProcessInfo.processInfo.environment["RAI_PAIR_URL"] {
            NSLog("rai-ios: RAI_PAIR_URL present: \(urlString)")
            if let launchPairing = try? Pairing(urlString: urlString) {
                pair(launchPairing)
                return
            } else {
                NSLog("rai-ios: RAI_PAIR_URL failed to parse")
            }
        }
        pairing = pairingStore.load()
        if let pairing {
            connection.connect(to: pairing)
        }
    }

    func pair(_ pairing: Pairing) {
        self.pairing = pairing
        connection.connect(to: pairing)
        do {
            try pairingStore.save(pairing)
        } catch {
            // Connecting must not depend on Keychain availability. In particular,
            // unsigned simulator builds may lack the required entitlement.
            NSLog("rai-ios: Could not persist pairing: \(error.localizedDescription)")
        }
    }

    func forgetPairing() {
        connection.disconnect()
        pairingStore.clear()
        pairing = nil
    }

    func setPushDeviceToken(_ token: String) {
        deviceToken = token
        registerPushIfPossible()
    }

    private func registerPushIfPossible() {
        guard let deviceToken, connection.status.isConnected else { return }
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        connection.registerPush(deviceToken: deviceToken, environment: environment)
    }
}
