import AppKit
import XCTest
@testable import RaiApp

@MainActor
final class AppTerminationTests: XCTestCase {
    func testUpdateQuitRunsOutsideTheCallingTask() async {
        let terminated = expectation(description: "termination requested")
        var callReturned = false
        var terminationCount = 0
        await Task { @MainActor in
            AppTermination.schedule {
                XCTAssertTrue(callReturned)
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertTrue(withUnsafeCurrentTask { $0 == nil })
                terminationCount += 1
                terminated.fulfill()
            }
            XCTAssertEqual(terminationCount, 0)
            callReturned = true
        }.value
        await fulfillment(of: [terminated], timeout: 2)
        XCTAssertEqual(terminationCount, 1)
    }
}
