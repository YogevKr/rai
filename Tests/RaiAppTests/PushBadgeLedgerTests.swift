import XCTest

@testable import RaiApp

final class PushBadgeLedgerTests: XCTestCase {
    func testFailedRetractionKeepsDeviceAlertInNextBadge() {
        var ledger = PushBadgeLedger<String>()
        ledger.commitAlert(identifiers: ["agent-p1"], for: "success")
        ledger.commitAlert(identifiers: ["agent-p1"], for: "failure")

        ledger.commitRetraction(identifiers: ["agent-p1"], for: "success")

        XCTAssertEqual(
            ledger.proposedBadge(adding: ["agent-p2"], for: "success"),
            1
        )
        XCTAssertEqual(
            ledger.proposedBadge(adding: ["agent-p2"], for: "failure"),
            2
        )
    }

    func testPartialRetractionRemovesOnlyAcceptedIdentifiers() {
        var ledger = PushBadgeLedger<String>()
        ledger.commitAlert(identifiers: ["agent-p1"], for: "phone")
        ledger.commitAlert(identifiers: ["agent-p2"], for: "phone")

        ledger.commitRetraction(identifiers: ["agent-p1"], for: "phone")

        XCTAssertEqual(
            ledger.proposedBadge(adding: ["agent-p3"], for: "phone"),
            2
        )
    }
}
