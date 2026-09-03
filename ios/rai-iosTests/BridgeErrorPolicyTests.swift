import Foundation
import RaiCore
import XCTest

@testable import rai

final class BridgeErrorPolicyTests: XCTestCase {
    func testEverySharedBridgeCodeHasAPhonePolicy() {
        let operationExpected: [BridgeErrorCode: BridgeErrorDestination] = [
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
        let authenticationExpected: [BridgeErrorCode: BridgeErrorDestination] = [
            .herdMissing: .reconnect,
            .paneGone: .reconnect,
            .paneBusy: .reconnect,
            .auditUnavailable: .reconnect,
            .repairRequired: .pairAgain,
            .pairingCodeInvalid: .pairAgain,
            .protocolMismatch: .updateRequired,
            .unknownMessage: .reconnect,
            .invalidRequest: .reconnect,
            .operationFailed: .reconnect,
            .streamUnavailable: .reconnect,
            .scrollbackUnavailable: .reconnect,
        ]

        XCTAssertEqual(Set(operationExpected.keys), Set(BridgeErrorCode.allCases))
        XCTAssertEqual(Set(authenticationExpected.keys), Set(BridgeErrorCode.allCases))
        XCTAssertEqual(BridgeErrorPolicy.destinations[.authentication], authenticationExpected)
        XCTAssertEqual(BridgeErrorPolicy.destinations[.operation], operationExpected)
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

    func testAuthenticationOperationFailureUsesTransientRetryPolicy() {
        XCTAssertEqual(
            BridgeErrorPolicy.destination(for: .operationFailed, phase: .authentication),
            .reconnect
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

    @MainActor
    func testTransientAuthenticationFailureKeepsReconnectBackoff() {
        let connection = BridgeConnection()

        connection.handle(.authFailed(
            reason: "Herdr is not connected.",
            code: .herdMissing,
            detail: "Mac startup is still in progress."
        ))

        XCTAssertTrue(connection.hasPendingReconnect)
        XCTAssertFalse(connection.requiresRepair)
        XCTAssertEqual(connection.status.diagnosis?.action, .reconnect)
    }

    @MainActor
    func testProtocolMismatchStopsWithoutRequiringRepair() {
        let connection = BridgeConnection()

        connection.handle(.authFailed(
            reason: "Protocol mismatch",
            code: .protocolMismatch,
            detail: "Phone protocol 6; Mac protocol 7."
        ))

        XCTAssertFalse(connection.hasPendingReconnect)
        XCTAssertFalse(connection.requiresRepair)
        XCTAssertTrue(connection.status.label.contains("update Rai"))
    }

    @MainActor
    func testUnknownAuthenticationCodeDefaultsToTransientRetry() throws {
        let data = Data(
            #"{"type":"authFailed","reason":"Mac is starting","code":"startup_pending","detail":"Herd not ready"}"#.utf8
        )
        let connection = BridgeConnection()

        connection.handle(try JSONDecoder().decode(BridgeMessage.self, from: data))

        XCTAssertTrue(connection.hasPendingReconnect)
        XCTAssertFalse(connection.requiresRepair)
        XCTAssertTrue(connection.status.diagnosis?.rawDetails.contains("startup_pending") == true)
    }
}
