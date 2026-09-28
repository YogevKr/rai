import XCTest
@testable import RaiApp

final class NotificationDeliveryPolicyTests: XCTestCase {
    func testSelectedPaneNotifiesWhenRaiIsOnAnotherSpace() {
        let cases: [(String, String?, Bool, Bool)] = [
            ("pane-1", "pane-1", true, false),
            ("pane-1", "pane-1", false, true),
            ("pane-2", "pane-1", true, true),
        ]

        for (paneID, selectedPaneID, raiIsVisible, expected) in cases {
            XCTAssertEqual(
                NotificationDeliveryPolicy.shouldDeliver(
                    paneID: paneID,
                    selectedPaneID: selectedPaneID,
                    raiIsVisible: raiIsVisible
                ),
                expected,
                "pane=\(paneID), selected=\(selectedPaneID ?? "nil"), visible=\(raiIsVisible)"
            )
        }
    }
}
