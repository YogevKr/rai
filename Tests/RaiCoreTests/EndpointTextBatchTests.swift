import RaiCore
import XCTest

@MainActor
final class EndpointTextBatchTests: XCTestCase {
    func testBurstPreservesUnicodeAndStopsAtTheByteBound() {
        let batch = EndpointTextBatch(context: "pane-one", text: "")
        let unit = "ßג"
        for _ in 0..<8192 { XCTAssertTrue(batch.append(unit, context: "pane-one")) }
        XCTAssertEqual(batch.text.utf8.count, 32_768)
        XCTAssertFalse(batch.append("x", context: "pane-one"))
        XCTAssertEqual(batch.seal(), String(repeating: unit, count: 8192))
        XCTAssertEqual(batch.byteCount, 32_768 + 16)
        XCTAssertFalse(batch.append("", context: "pane-one"))
    }

    func testTargetChangesAndStartedWritesCannotMerge() {
        let batch = EndpointTextBatch(context: "pane-one:popup-one:epoch-one", text: "first")
        XCTAssertFalse(batch.append("foreign", context: "pane-one:popup-two:epoch-one"))
        XCTAssertFalse(batch.append("foreign", context: "pane-one:popup-one:epoch-two"))
        XCTAssertEqual(batch.seal(), "first")
        XCTAssertFalse(batch.append("late", context: "pane-one:popup-one:epoch-one"))
        XCTAssertEqual(batch.text, "first")
    }
}
