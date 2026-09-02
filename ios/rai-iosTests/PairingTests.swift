import XCTest

@testable import rai

final class PairingTests: XCTestCase {
    func testPairingURLParsesOneTimeCodeForLANAndTLS() throws {
        XCTAssertEqual(
            try PairingInvitation(
                urlString: "rai://pair?host=mac.local&port=47837&code=23456789"
            ),
            try PairingInvitation(
                host: "mac.local",
                port: 47837,
                code: "23456789"
            )
        )
        XCTAssertEqual(
            try PairingInvitation(
                urlString: "rai://pair?host=mac.example.ts.net&port=8443&code=ABCDEFGH&tls=1"
            ),
            try PairingInvitation(
                host: "mac.example.ts.net",
                port: 8443,
                code: "ABCDEFGH",
                useTLS: true
            )
        )
        XCTAssertThrowsError(
            try PairingInvitation(
                urlString: "rai://pair?host=mac.local&port=47837&token=permanent"
            )
        )
    }

    @MainActor
    func testExchangeReplyCreatesPersistentCredentialShape() throws {
        let invitation = try PairingInvitation(
            host: "mac.local",
            port: 47837,
            code: "23456789"
        )
        let token = String(repeating: "a", count: 43)
        let pairing = try BridgeConnection.exchangedPairing(
            token: token,
            invitation: invitation
        )

        XCTAssertEqual(pairing.host, invitation.host)
        XCTAssertEqual(pairing.port, invitation.port)
        XCTAssertEqual(pairing.useTLS, invitation.useTLS)
        XCTAssertEqual(pairing.token, token)
        XCTAssertNotEqual(pairing.token, invitation.code)
        XCTAssertThrowsError(
            try BridgeConnection.exchangedPairing(
                token: "invalid reply",
                invitation: invitation
            )
        )
    }

    @MainActor
    func testKeychainFailureKeepsExchangedCredentialInMemory() throws {
        let store = FailingPairingStore()
        let model = AppModel(
            pairingStore: store,
            connection: BridgeConnection(),
            launchPairURL: nil
        )
        let pairing = try Pairing(
            host: "mac.local",
            port: 47837,
            token: "device-bearer-token"
        )

        model.didExchangeCredential(pairing)

        XCTAssertEqual(model.pairing, pairing)
        XCTAssertTrue(store.didTrySave)
    }

    @MainActor
    func testOldMacPairRejectionRequiresRepairOnlyDuringPairing() {
        let error = "Invalid bridge message: unknown type pair"

        XCTAssertTrue(
            BridgeConnection.isPairingProtocolRejection(
                error,
                pairingInProgress: true
            )
        )
        XCTAssertFalse(
            BridgeConnection.isPairingProtocolRejection(
                error,
                pairingInProgress: false
            )
        )
        XCTAssertFalse(
            BridgeConnection.isPairingProtocolRejection(
                "Could not read scrollback",
                pairingInProgress: true
            )
        )
    }
}

private final class FailingPairingStore: PairingStoring {
    private(set) var didTrySave = false

    func load() -> Pairing? { nil }

    func save(_ pairing: Pairing) throws {
        didTrySave = true
        throw PairingError.keychain(-1)
    }

    func clear() {}
}
