import Foundation
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
        XCTAssertEqual(BridgeErrorPolicy.destinations[.authentication], expected)
        XCTAssertEqual(BridgeErrorPolicy.destinations[.operation], expected)
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

        let repair = ConnectionDiagnosis.coded(
            .repairRequired,
            message: "Changed prose",
            detail: "Token revoked",
            host: "Mac"
        )
        XCTAssertEqual(repair.action, .pairAgain)
        XCTAssertEqual(repair.rawDetails, "Token revoked")
    }

    func testAuthenticationOperationFailureUsesActionErrorPolicy() {
        XCTAssertEqual(
            BridgeErrorPolicy.destination(for: .operationFailed, phase: .authentication),
            .actionError
        )
    }

    @MainActor
    func testRepairRequiredAuthenticationStopsReconnectAndRequiresPairing() {
        let connection = BridgeConnection()
        connection.scheduleReconnect(after: URLError(.networkConnectionLost))
        XCTAssertTrue(connection.hasPendingReconnect)

        connection.handle(.authFailed(
            reason: "Re-pair required",
            code: .repairRequired,
            detail: "The paired device credential was revoked."
        ))

        guard case let .failed(diagnosis) = connection.status else {
            return XCTFail("Expected a failed connection status")
        }
        XCTAssertEqual(diagnosis.action, .pairAgain)
        XCTAssertTrue(connection.requiresRepair)
        XCTAssertFalse(connection.hasPendingReconnect)
    }
}
