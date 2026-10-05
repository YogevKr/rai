import UIKit
import Vision
import XCTest

/// Opt-in test against a paired, isolated app with an open Codex conversation.
/// Use a fresh conversation with "1. Line 1" through "100. Line 100", then 101 through 200.
/// Earlier responses with repeated line numbers make the OCR position ambiguous.
@MainActor
final class CodexScrollUITests: XCTestCase {
    func testRepeatedSwipesReachOldestLinesAndReturn() throws {
        let app = try isolatedApp()
        try checkHistoryRoundTrip(app, upperY: 0.22, lowerY: 0.40)
    }

    func testKeyboardChangesKeepOlderMessagesReachable() throws {
        let app = try isolatedApp()
        if app.buttons["Hide keyboard"].exists { app.buttons["Hide keyboard"].tap() }
        try scrollToSecondResponse(app)
        app.buttons["Type directly in terminal"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        // Keep both points inside the smaller terminal above the open keyboard.
        try checkHistoryRoundTrip(app, upperY: 0.22, lowerY: 0.34)
        XCTAssertTrue(app.keyboards.firstMatch.exists, "The round trip must cover the smaller keyboard viewport")
        app.buttons["Hide keyboard"].tap()
        try checkHistoryRoundTrip(app, upperY: 0.22, lowerY: 0.40)
    }

    func testReopenedPaneKeepsOlderMessagesReachable() throws {
        let app = try isolatedApp()
        if app.buttons["Hide keyboard"].exists { app.buttons["Hide keyboard"].tap() }
        try scrollToSecondResponse(app)
        // This explicit lab fixture opens the same pane through a fresh connection.
        app.launchEnvironment["RAI_OPEN_PANE"] = "w1:p1"
        app.terminate()
        app.launch()
        try checkHistoryRoundTrip(app, upperY: 0.22, lowerY: 0.40)
    }

    private func scrollToSecondResponse(_ app: XCUIApplication) throws {
        var current = try waitForLine(app) { _ in true }
        let upper = app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.22))
        let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.40))
        for _ in 0..<12 {
            if current >= 150 { return }
            lower.press(forDuration: 0.05, thenDragTo: upper, withVelocity: .slow, thenHoldForDuration: 0)
            // A native pan can first reveal the grid footer without changing
            // the first numbered line. The bounded loop still requires Line 150.
            current = try waitForLine(app) { _ in true }
        }
        XCTAssertGreaterThanOrEqual(current, 150, "Use the two-response fixture ending at Line 200.")
    }

    private func checkHistoryRoundTrip(_ app: XCUIApplication, upperY: CGFloat, lowerY: CGFloat) throws {
        let initial = try waitForLine(app) { $0 >= 40 }
        let upper = app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: upperY))
        let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: lowerY))
        var current = initial
        var readings = [initial]
        for step in 1...24 {
            if current <= 5 { break }
            let previous = current
            upper.press(forDuration: 0.05, thenDragTo: lower, withVelocity: .slow, thenHoldForDuration: 0)
            // Revealing a partial row can keep the same first numbered line.
            // Require monotonic movement and reaching the oldest lines overall.
            current = try waitForLine(app) { $0 <= previous }
            readings.append(current)
            capture(app, name: "Earlier history swipe \(step)")
        }
        XCTAssertLessThanOrEqual(current, 5, "Swipes must reach the oldest numbered lines.")
        for step in 1...24 {
            if current >= initial { break }
            let previous = current
            lower.press(forDuration: 0.05, thenDragTo: upper, withVelocity: .slow, thenHoldForDuration: 0)
            current = try waitForLine(app) { $0 >= previous }
            readings.append(current)
            capture(app, name: "Later history swipe \(step)")
        }
        XCTAssertGreaterThanOrEqual(current, initial, "Swipes must return to the initial reading position.")
        let evidence = XCTAttachment(string: "First visible lines: \(readings)")
        evidence.name = "Full history line checks"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    func testTouchSwipesMoveCodexConversationInBothDirections() throws {
        let app = try isolatedApp()
        let initial = try waitForLine(app) { _ in true }
        capture(app, name: "Before swipe")

        // Coordinates stay inside the terminal, above the input controls.
        let upper = app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.22))
        let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.40))
        upper.press(forDuration: 0.05, thenDragTo: lower, withVelocity: .slow, thenHoldForDuration: 0)
        let earlier = try waitForLine(app) { $0 <= initial - 5 }
        capture(app, name: "Earlier lines after downward swipe")

        lower.press(forDuration: 0.05, thenDragTo: upper, withVelocity: .slow, thenHoldForDuration: 0)
        let later = try waitForLine(app) { $0 >= earlier + 5 }
        capture(app, name: "Later lines after upward swipe")
        XCTAssertLessThan(earlier, initial)
        XCTAssertGreaterThan(later, earlier)
        let readings = XCTAttachment(string: "First visible lines: \(initial), \(earlier), \(later)")
        readings.name = "Numbered line checks"
        readings.lifetime = .keepAlways
        add(readings)
    }

    private func isolatedApp() throws -> XCUIApplication {
        let testBundle = try XCTUnwrap(Bundle(for: Self.self).bundleIdentifier)
        let suffix = ".scroll-tests"
        let bundle = String(testBundle.dropLast(suffix.count))
        guard testBundle.hasSuffix(suffix), bundle.hasPrefix("com.whetstone.rai.ios.lab.") else {
            throw XCTSkip("Use a paired lab bundle. This test cannot open the regular app.")
        }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: bundle)
        // XCTest can stop the app between runs. Reopen the lab fixture on launch.
        app.launchEnvironment["RAI_OPEN_PANE"] = "w1:p1"
        if app.state == .notRunning {
            app.launch()
        } else {
            app.activate()
        }
        return app
    }

    private func waitForLine(_ app: XCUIApplication, matching predicate: @escaping (Int) -> Bool) throws -> Int {
        var matched: Int?
        var last: Int?
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            last = try? self.firstVisibleLine(app)
            if let last, predicate(last) { matched = last; return true }
            return false
        }, object: nil)
        let result = XCTWaiter.wait(for: [expectation], timeout: 10)
        guard result == .completed, let matched else {
            capture(app, name: "Scroll failure")
            XCTFail("Expected numbered Codex lines to move. Last first visible line: \(String(describing: last))")
            throw NSError(domain: "CodexScrollUITests", code: 1)
        }
        return matched
    }

    private func firstVisibleLine(_ app: XCUIApplication) throws -> Int? {
        let screenshot = app.screenshot()
        let image = try XCTUnwrap(UIImage(data: screenshot.pngRepresentation)?.cgImage)
        let pattern = try NSRegularExpression(pattern: #"\bLine\s+(\d+)\b"#)
        // OCR can group a dense terminal column vertically and omit its numbers.
        // Read overlapping strips below the toolbar to preserve individual rows.
        let height = max(60, image.height / 26)
        for y in stride(from: image.height / 7, to: image.height / 2, by: height * 4 / 5) {
            let crop = try XCTUnwrap(image.cropping(to:
                CGRect(x: 0, y: y, width: image.width / 2, height: height)))
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: crop).perform([request])
            let lines = (request.results ?? []).compactMap { observation -> Int? in
                guard let text = observation.topCandidates(1).first?.string,
                      let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                      let range = Range(match.range(at: 1), in: text) else { return nil }
                return Int(text[range])
            }
            if let first = lines.min() { return first }
        }
        return nil
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
