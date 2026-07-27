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
        // Revoke push delivery on the Mac before dropping the socket, otherwise
        // it keeps this device registered and notifying after the user has
        // explicitly forgotten the pairing.
        let token = deviceToken
        Task {
            if let token, connection.status.isConnected {
                await connection.unregisterPush(deviceToken: token)
            }
            connection.disconnect()
        }
        pairingStore.clear()
        pairing = nil
    }

    func setPushDeviceToken(_ token: String) {
        deviceToken = token
        registerPushIfPossible()
    }

    func sendNotificationInput(_ bytes: [UInt8], to paneID: String) async -> Bool {
        guard let pairing else { return false }
        return await connection.connectAndSendInput(bytes, to: paneID, pairing: pairing)
    }

    private func registerPushIfPossible() {
        guard let deviceToken, connection.status.isConnected else { return }
        connection.registerPush(
            deviceToken: deviceToken,
            environment: Self.apnsEnvironment
        )
    }

    /// The APNs token's environment is fixed by the signed `aps-environment`
    /// entitlement, not the build configuration — a Release build run from Xcode
    /// on a development profile still gets a *sandbox* token. Read it from the
    /// embedded provisioning profile; fall back to the build config when there
    /// is no profile (e.g. the simulator).
    static let apnsEnvironment: String = {
        if let url = Bundle.main.url(
            forResource: "embedded",
            withExtension: "mobileprovision"
        ),
           let data = try? Data(contentsOf: url),
           let raw = String(data: data, encoding: .ascii),
           let start = raw.range(of: "<plist"),
           let end = raw.range(of: "</plist>"),
           let plistData = String(raw[start.lowerBound..<end.upperBound])
               .data(using: .utf8),
           let plist = try? PropertyListSerialization.propertyList(
               from: plistData, format: nil
           ) as? [String: Any],
           let entitlements = plist["Entitlements"] as? [String: Any],
           let aps = entitlements["aps-environment"] as? String {
            // Entitlement values are "development" or "production".
            return aps == "production" ? "production" : "sandbox"
        }
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }()
}
