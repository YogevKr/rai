import RaiCore
import XCTest

@testable import rai

final class BridgeErrorPolicyTests: XCTestCase {
    func testEverySharedBridgeCodeHasAPhonePolicy() {
        let expected: [BridgeErrorCode: BridgeErrorDestination] = [
            .herdMissing: .reconnect,
            .paneGone: .actionError,
            .paneBusy: .actionError,
            .auditUnavailable: .actionError,
            .repairRequired: .pairAgain,
            .pairingCodeInvalid: .pairAgain,
            .protocolMismatch: .reconnect,
            .unknownMessage: .actionError,
            .invalidRequest: .actionError,
            .operationFailed: .actionError,
            .streamUnavailable: .actionError,
            .scrollbackUnavailable: .ignore,
        ]

        XCTAssertEqual(Set(expected.keys), Set(BridgeErrorCode.allCases))
        XCTAssertEqual(BridgeErrorPolicy.destinations, expected)
    }

    func testCodedDiagnosesUseStableActionsAndDetail() {
        let missing = ConnectionDiagnosis.coded(
            .herdMissing,
            message: "Changed prose",
            detail: "No live snapshot",
            host: "studio.local"
        )
        XCTAssertEqual(missing.action, .reconnect)
        XCTAssertEqual(missing.message, "herdr isn't running on the Mac")
        XCTAssertEqual(missing.rawDetails, "No live snapshot")

        let repair = ConnectionDiagnosis.authFailure(
            code: .repairRequired,
            reason: "Changed prose",
            detail: "Token revoked"
        )
        XCTAssertEqual(repair.action, .pairAgain)
        XCTAssertEqual(repair.rawDetails, "Token revoked")
    }
}
