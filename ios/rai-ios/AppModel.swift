import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var pairing: Pairing?
    let connection = BridgeConnection()

    private let pairingStore = PairingStore()

    init() {
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
