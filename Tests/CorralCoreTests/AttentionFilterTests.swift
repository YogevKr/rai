import CorralCore
import XCTest

final class AttentionFilterTests: XCTestCase {
    func testFilterOffIncludesEveryStatus() {
        for status in AgentStatus.allCases {
            XCTAssertTrue(
                AttentionFilter.includes(
                    status: status,
                    id: "tab",
                    selectedID: nil as String?,
                    onlyNeedsYou: false
                )
            )
        }
    }

    func testFilterOnIncludesOnlyBlockedAndSelected() {
        XCTAssertTrue(
            AttentionFilter.includes(
                status: .blocked,
                id: "blocked",
                selectedID: "other",
                onlyNeedsYou: true
            )
        )
        XCTAssertTrue(
            AttentionFilter.includes(
                status: .working,
                id: "selected",
                selectedID: "selected",
                onlyNeedsYou: true
            )
        )
        XCTAssertFalse(
            AttentionFilter.includes(
                status: .done,
                id: "done",
                selectedID: "selected",
                onlyNeedsYou: true
            )
        )
    }
}
