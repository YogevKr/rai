import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var pairing: Pairing?
    let connection = BridgeConnection()

    private let pairingStore = PairingStore()

    init() {
        // Testing/automation affordance: pair straight from a launch env var,
        // e.g. `simctl launch --setenv RAI_PAIR_URL "rai://pair?..."`. Harmless
        // in normal use (the var is never set); lets e2e tests skip the QR/UI.
        if let urlString = ProcessInfo.processInfo.environment["RAI_PAIR_URL"] {
            NSLog("rai-ios: RAI_PAIR_URL present: \(urlString)")
            if let launchPairing = try? Pairing(urlString: urlString) {
                // Connect directly — don't let a Keychain-save failure (unsigned
                // simulator builds lack the entitlement) block the connection.
                pairing = launchPairing
                try? pairingStore.save(launchPairing)
                connection.connect(to: launchPairing)
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

    func pair(_ pairing: Pairing) throws {
        try pairingStore.save(pairing)
        self.pairing = pairing
        connection.connect(to: pairing)
    }

    func forgetPairing() {
        connection.disconnect()
        pairingStore.clear()
        pairing = nil
    }
}
