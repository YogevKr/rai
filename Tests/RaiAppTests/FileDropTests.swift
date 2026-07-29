import AppKit
import UniformTypeIdentifiers
import XCTest

@testable import RaiApp

/// The SwiftUI `.onDrop` path for files dragged onto a terminal pane: the
/// sidebar's reorder `.onDrop` makes SwiftUI own the window's AppKit drag
/// destination, so file drops must be claimed at the SwiftUI layer and
/// forwarded to the pty as one escaped path line.
final class FileDropTests: XCTestCase {
    @MainActor
    func testDeliversEscapedPathsInProviderOrder() {
        let providers = [
            NSItemProvider(object: NSURL(fileURLWithPath: "/tmp/one.txt")),
            NSItemProvider(object: NSURL(fileURLWithPath: "/tmp/two three.txt")),
        ]
        let expectation = expectation(description: "drop delivered")
        var delivered: String?
        let accepted = FileDrop.deliver(providers) { line in
            delivered = line
            expectation.fulfill()
        }
        XCTAssertTrue(accepted)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(delivered, "/tmp/one.txt /tmp/two\\ three.txt ")
    }

    @MainActor
    func testRejectsDropsWithoutFileURLs() {
        let providers = [NSItemProvider(object: "just text" as NSString)]
        XCTAssertFalse(FileDrop.deliver(providers) { _ in
            XCTFail("non-file drop must not send")
        })
    }
}
