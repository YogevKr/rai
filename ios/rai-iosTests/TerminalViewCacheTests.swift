import RaiCore
import SwiftUI
import UIKit
import XCTest
@testable import rai

@MainActor
final class TerminalViewCacheTests: XCTestCase {
    private func surface() -> TerminalSurface {
        let terminal = GridReadableTerminalView(frame: CGRect(x: 0, y: 0, width: 650, height: 70))
        terminal.changeScrollback(2_000)
        terminal.pinGridSize(cols: 80, rows: 4)
        let scroll = UIScrollView(frame: terminal.frame)
        scroll.addSubview(terminal)
        return TerminalSurface(
            scroll: scroll, terminal: terminal,
            widthFloor: terminal.widthAnchor.constraint(greaterThanOrEqualToConstant: 650),
            baseWidthFloor: 650, charWidth: 8
        )
    }

    private func key(_ paneID: String, scope: UUID = UUID()) -> TerminalCacheKey {
        TerminalCacheKey(scope: scope, paneID: paneID, terminalID: paneID, agentSessionID: nil)
    }

    func testReturnRetainsTerminalCellsHistoryAndScrollPosition() throws {
        let cache = TerminalViewCache()
        let key = key("pane")
        let surface = surface()
        let terminal = surface.terminal
        let history = Data(((0..<40).map { "old \($0)" }.joined(separator: "\n") + "\n").utf8)
        let frame = Data("\u{1B}[H\u{1B}[32mlive\u{1B}[2;1Hprompt".utf8)
        terminal.receiveHistory(history)
        terminal.receiveFrame(frame, full: true, grid: PaneGridSize(cols: 80, rows: 4))
        terminal.scrollTo(row: 5)
        let oldRow = terminal.getTerminal().buffer.yDisp
        let oldOffset = terminal.contentOffset
        let oldCells = terminal.getTerminal().getBufferAsData()
        let firstLine = terminal.getTerminal().getScrollInvariantLine(row: 0)
        cache.store(surface, for: key)

        let restored = try XCTUnwrap(cache.take(key))
        XCTAssertTrue(restored === surface)
        XCTAssertEqual(cache.count, 0, "An active terminal has one owner")
        restored.terminal.awaitNextConnectionFrame()
        XCTAssertEqual(restored.terminal.getTerminal().getBufferAsData(), oldCells)
        XCTAssertEqual(restored.terminal.cachedHistoryHash, PaneScrollback.contentHash(history))
        XCTAssertFalse(restored.terminal.hasLiveFrame, "Cached prompts are not live evidence")
        XCTAssertEqual(restored.terminal.receiveFrame(
            frame, full: true, grid: PaneGridSize(cols: 80, rows: 4)
        ), .applied, "A return must not schedule scrollToLive while reading history")
        XCTAssertEqual(restored.terminal.getTerminal().buffer.yDisp, oldRow)
        XCTAssertEqual(restored.terminal.contentOffset, oldOffset)
        XCTAssertTrue(firstLine === restored.terminal.getTerminal().getScrollInvariantLine(row: 0))
        restored.terminal.receiveFrame(Data("\u{1B}[2;7H!".utf8), full: false, grid: nil)
        XCTAssertTrue(restored.terminal.liveGridText().contains("prompt!"))
    }

    func testCacheEvictsOldestViewAndMemoryWarningClearsDetachedViews() async {
        let notifications = NotificationCenter()
        let cache = TerminalViewCache(capacity: 2, notificationCenter: notifications)
        let keys = (0..<3).map { key("pane-\($0)") }
        let references = keys.map { key in
            let surface = surface()
            let reference = WeakTerminal(surface.terminal)
            cache.store(surface, for: key)
            return reference
        }
        XCTAssertNil(cache.take(keys[0]))
        XCTAssertEqual(cache.count, 2)
        notifications.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        await eventually { cache.count == 0 && references.allSatisfy { $0.value == nil } }
        XCTAssertEqual(cache.count, 0)
    }

    func testReturnPreservesPositionInsideTallLiveGrid() {
        let terminal = surface().terminal
        let grid = PaneGridSize(cols: 80, rows: 40)
        let frame = Data("\u{1B}[Htop row\u{1B}[40;1Hlive cursor".utf8)
        terminal.receiveFrame(frame, full: true, grid: grid)
        terminal.contentOffset.y = 30
        terminal.awaitNextConnectionFrame()
        XCTAssertEqual(terminal.receiveFrame(frame, full: true, grid: grid), .applied)
        XCTAssertEqual(terminal.contentOffset.y, 30)
    }

    func testReturningToTrimmedHistoryKeepsTheSameText() {
        let surface = surface()
        let terminal = surface.terminal
        func history(_ range: Range<Int>) -> Data {
            Data((range.map { "row \($0)" }.joined(separator: "\n") + "\n").utf8)
        }
        let grid = PaneGridSize(cols: 80, rows: 4)
        let frame = Data("\u{1B}[Hlive".utf8)
        terminal.receiveHistory(history(0..<40))
        terminal.receiveFrame(frame, full: true, grid: grid)
        terminal.scrollTo(row: 5)
        let offset = terminal.contentOffset.y
        let cellHeight = terminal.getOptimalFrameSize().height / 4
        terminal.awaitNextConnectionFrame()
        terminal.receiveHistory(history(3..<43))
        XCTAssertEqual(terminal.getTerminal().buffer.yDisp, 5, "Keep cached cells until a complete baseline")
        XCTAssertEqual(terminal.receiveFrame(frame, full: true, grid: grid), .applied)
        XCTAssertEqual(terminal.getTerminal().buffer.yDisp, 2)
        XCTAssertEqual(terminal.getTerminal().getLine(row: 0)?.translateToString(trimRight: true), "row 5")
        XCTAssertEqual(terminal.contentOffset.y, max(0, offset - 3 * cellHeight), accuracy: 0.5)

        terminal.awaitNextConnectionFrame()
        terminal.receiveHistory(Data())
        terminal.receiveFrame(frame, full: true, grid: grid)
        XCTAssertEqual(terminal.getTerminal().buffer.yDisp, 0)
        XCTAssertLessThanOrEqual(terminal.contentOffset.y, max(0, terminal.contentSize.height - terminal.bounds.height))
    }

    func testNativeGridResizeKeepsTheHistoryAnchorAndAppliesOnlyActualTrimming() {
        for rows in [2, 8, 50] {
            for removed in [0, 3] {
                let surface = surface()
                let terminal = surface.terminal
                func history(_ range: Range<Int>) -> Data {
                    Data((range.map { "row \($0)" }.joined(separator: "\n") + "\n").utf8)
                }
                let frame = Data("\u{1B}[Hlive".utf8)
                terminal.receiveHistory(history(0..<40))
                terminal.receiveFrame(frame, full: true, grid: PaneGridSize(cols: 80, rows: 4))
                terminal.scrollTo(row: 5)
                let cellHeight = terminal.getOptimalFrameSize().height / 4
                let expectedOffset = terminal.contentOffset.y - CGFloat(removed) * cellHeight
                terminal.awaitNextConnectionFrame()
                terminal.receiveHistory(history(removed..<(40 + removed)))
                XCTAssertEqual(terminal.receiveFrame(
                    frame, full: true, grid: PaneGridSize(cols: 80, rows: rows)
                ), .applied)
                XCTAssertEqual(terminal.getTerminal().buffer.yDisp, 5 - removed, "grid rows: \(rows)")
                XCTAssertEqual(terminal.getTerminal().getLine(row: 0)?.translateToString(trimRight: true), "row 5")
                XCTAssertEqual(terminal.contentOffset.y, expectedOffset, accuracy: 0.5)
                terminal.frame.size.height = 90
                terminal.setNeedsLayout()
                terminal.layoutIfNeeded()
                XCTAssertEqual(terminal.contentOffset.y, expectedOffset, accuracy: 0.5)
            }
        }
    }

    func testMissingBeaconKeepsCachedTerminalUntilTheAgentSessionChanges() throws {
        let connection = BridgeConnection(messageSender: { _ in })
        defer { connection.disconnect() }
        let base = try JSONDecoder().decode(SessionSnapshot.self, from: Data("""
        {"version":"test","protocol":1,"layouts":[],"panes":[{"pane_id":"pane","terminal_id":"term",
        "workspace_id":"w","tab_id":"t","focused":true,"cwd":"/test","agent":"claude",
        "agent_session":{"agent":"claude","kind":"path","source":"test","value":"/test/transcript"},
        "agent_status":"idle","revision":1}],"workspaces":[],"tabs":[]}
        """.utf8))
        func snapshot(_ id: String) -> SessionSnapshot {
            base.addingBeacons(["pane": AgentBeacon(
                event: "PreToolUse", sessionID: id, cwd: "/test",
                transcriptPath: "/test/transcript", timestamp: 0
            )])
        }
        connection.replaceWithLiveSnapshot(snapshot("first"))
        let firstKey = try XCTUnwrap(connection.terminalCacheKey(paneID: "pane"))
        let surface = surface()
        connection.terminalViewCache.store(surface, for: firstKey)

        // Stop and decision completion can remove the hook while the agent lives.
        connection.replaceWithLiveSnapshot(base)
        XCTAssertEqual(connection.terminalCacheKey(paneID: "pane"), firstKey)
        XCTAssertTrue(connection.terminalViewCache.take(firstKey) === surface)
        connection.terminalViewCache.store(surface, for: firstKey)
        connection.replaceWithLiveSnapshot(snapshot("first"))
        XCTAssertEqual(connection.terminalCacheKey(paneID: "pane"), firstKey)
        connection.replaceWithLiveSnapshot(snapshot("second"))
        let secondKey = try XCTUnwrap(connection.terminalCacheKey(paneID: "pane"))
        XCTAssertNotEqual(secondKey, firstKey)
        XCTAssertEqual(connection.terminalViewCache.count, 0)
        connection.replaceWithLiveSnapshot(base)
        XCTAssertEqual(connection.terminalCacheKey(paneID: "pane"), secondKey)

        let replacement = try JSONDecoder().decode(SessionSnapshot.self, from: Data(
            String(decoding: try JSONEncoder().encode(base), as: UTF8.self)
                .replacingOccurrences(of: "\"term\"", with: "\"replacement\"").utf8
        ))
        connection.replaceWithLiveSnapshot(replacement)
        XCTAssertNil(connection.terminalCacheKey(paneID: "pane")?.agentSessionID)
    }

    private final class WeakTerminal {
        weak var value: GridReadableTerminalView?
        init(_ value: GridReadableTerminalView) { self.value = value }
    }

    private final class TrackingTerminal: GridReadableTerminalView {
        var fingerDown = false
        override var isTracking: Bool { fingerDown || super.isTracking }
    }

    func testColumnReflowRetainsTheSameStyledHistoryText() {
        for (oldCols, newCols) in [(120, 80), (80, 120), (80, 40)] {
            for removed in [0, 3] {
                let surface = surface()
                let terminal = surface.terminal
                func history(_ range: Range<Int>) -> Data {
                    Data((range.map {
                        "\u{1B}[38;5;\($0 + 20)mline \($0): " + String(repeating: "x", count: 90)
                    }.joined(separator: "\n") + "\n").utf8)
                }
                func rowOfLineFive() -> Int? {
                    String(decoding: terminal.getTerminal().getBufferAsData(), as: UTF8.self)
                        .components(separatedBy: "\n").firstIndex { $0.hasPrefix("line 5:") }
                }
                let frame = Data("\u{1B}[Hlive".utf8)
                terminal.receiveHistory(history(0..<20))
                terminal.receiveFrame(frame, full: true, grid: PaneGridSize(cols: oldCols, rows: 4))
                terminal.scrollTo(row: rowOfLineFive() ?? -1)
                let attribute = terminal.getTerminal().getLine(row: 0)?[0].attribute
                terminal.awaitNextConnectionFrame()
                terminal.receiveHistory(history(removed..<(20 + removed)))
                terminal.receiveFrame(frame, full: true, grid: PaneGridSize(cols: newCols, rows: 8))
                XCTAssertEqual(terminal.getTerminal().buffer.yDisp, rowOfLineFive(), "\(oldCols) -> \(newCols)")
                XCTAssertTrue(terminal.getTerminal().getLine(row: 0)?.translateToString(trimRight: true)
                    .hasPrefix("line 5:") == true)
                XCTAssertEqual(terminal.getTerminal().getLine(row: 0)?[0].attribute, attribute)
            }
        }
    }

    func testDeferredNativeResizeRetainsTheOriginalHistoryAnchor() async {
        for removed in [0, 3] {
            for finalRows in [4, 50] {
                let terminal = TrackingTerminal(frame: CGRect(x: 0, y: 0, width: 650, height: 100))
                defer { terminal.updateUiClosed() }
                terminal.changeScrollback(2_000)
                func history(_ range: Range<Int>) -> Data {
                    Data((range.map { "row \($0)" }.joined(separator: "\n") + "\n").utf8)
                }
                let frame = Data("\u{1B}[Hlive".utf8)
                terminal.receiveHistory(history(0..<40))
                terminal.receiveFrame(frame, full: true, grid: PaneGridSize(cols: 80, rows: 4))
                terminal.scrollTo(row: 5)
                let cellHeight = terminal.getOptimalFrameSize().height / 4
                terminal.awaitNextConnectionFrame()
                terminal.receiveHistory(history(removed..<(40 + removed)))
                terminal.fingerDown = true
                terminal.receiveFrame(frame, full: true, grid: PaneGridSize(cols: 80, rows: 50))
                terminal.receiveFrame(frame, full: true, grid: PaneGridSize(cols: 80, rows: finalRows))
                terminal.receiveFrame(Data("\u{1B}[2;1Hdelta".utf8), full: false, grid: nil)
                terminal.fingerDown = false
                await eventually {
                    terminal.getTerminal().getLine(row: 0)?.translateToString(trimRight: true) == "row 5"
                }
                XCTAssertEqual(terminal.getTerminal().buffer.yDisp, 5 - removed)
                XCTAssertEqual(terminal.cachedHistoryHash, PaneScrollback.contentHash(history(removed..<(40 + removed))))
                XCTAssertEqual(terminal.contentOffset.y, CGFloat(5 - removed) * cellHeight, accuracy: 0.5)
            }
        }
    }

    func testOrdinaryHistoryUpdateKeepsTheFinalGesturePosition() async {
        let terminal = TrackingTerminal(frame: CGRect(x: 0, y: 0, width: 650, height: 100))
        defer { terminal.updateUiClosed() }
        terminal.changeScrollback(2_000)
        func history(_ range: Range<Int>) -> Data {
            Data((range.map { "row \($0)" }.joined(separator: "\n") + "\n").utf8)
        }
        terminal.receiveHistory(history(0..<40))
        terminal.receiveFrame(Data("\u{1B}[Hlive".utf8), full: true, grid: PaneGridSize(cols: 80, rows: 4))
        let cellHeight = terminal.getOptimalFrameSize().height / 4
        terminal.scrollTo(row: 5)
        terminal.fingerDown = true
        terminal.receiveHistory(history(0..<44))
        terminal.contentOffset.y = 20 * cellHeight
        terminal.fingerDown = false
        await eventually { terminal.cachedHistoryHash == PaneScrollback.contentHash(history(0..<44)) }
        XCTAssertEqual(terminal.getTerminal().buffer.yDisp, 20)
        XCTAssertEqual(terminal.getTerminal().getLine(row: 0)?.translateToString(trimRight: true), "row 20")
        terminal.frame.size.height = 80
        terminal.setNeedsLayout()
        terminal.layoutIfNeeded()
        XCTAssertEqual(terminal.contentOffset.y, 20 * cellHeight, accuracy: 0.5)
    }

    func testHistoryRefreshKeepsManualGridPositionAfterViewportResize() {
        let terminal = TrackingTerminal(frame: CGRect(x: 0, y: 0, width: 650, height: 100))
        defer { terminal.updateUiClosed() }
        terminal.changeScrollback(2_000)
        let grid = PaneGridSize(cols: 80, rows: 40)
        let frame = Data("\u{1B}[Htop\u{1B}[40;1Hlive cursor".utf8)
        terminal.receiveHistory(Data("old\n".utf8))
        terminal.receiveFrame(frame, full: true, grid: grid)
        terminal.layoutIfNeeded()
        terminal.scrollToLive()
        let cellHeight = terminal.getOptimalFrameSize().height / 40
        terminal.fingerDown = true
        terminal.contentOffset.y = 6.5 * cellHeight
        terminal.fingerDown = false
        XCTAssertEqual(terminal.getTerminal().buffer.yDisp, 1)

        terminal.awaitNextConnectionFrame()
        terminal.receiveHistory(Data("old\nnew\nnewer\n".utf8))
        XCTAssertEqual(terminal.receiveFrame(frame, full: true, grid: grid), .applied)
        let expectedOffset = 8.5 * cellHeight
        XCTAssertEqual(terminal.contentOffset.y, expectedOffset, accuracy: 0.5)
        terminal.frame.size.height = 150
        terminal.setNeedsLayout()
        terminal.layoutIfNeeded()
        XCTAssertEqual(terminal.contentOffset.y, expectedOffset, accuracy: 0.5,
                       "A keyboard or viewport change must keep the reader inside the grid")
        terminal.receiveHistory(Data("old\nnew\nnewer\nlast\n".utf8))
        terminal.frame.size.height = 90
        terminal.setNeedsLayout()
        terminal.layoutIfNeeded()
        XCTAssertEqual(terminal.contentOffset.y, expectedOffset + cellHeight, accuracy: 0.5)
    }

    func testDiscardedSurfacesReleaseTheirDisplayLinksAndTerminals() async {
        let cache = TerminalViewCache(capacity: 1)
        let first = key("first")
        let second = key("second")
        func store(_ key: TerminalCacheKey, in cache: TerminalViewCache) -> WeakTerminal {
            let surface = surface()
            let reference = WeakTerminal(surface.terminal)
            cache.store(surface, for: key)
            return reference
        }
        let evicted = store(first, in: cache)
        let replaced = store(second, in: cache)
        let pruned = store(second, in: cache)
        cache.retain([])
        let cleared = store(first, in: cache)
        cache.removeAll()
        let rejected = store(first, in: TerminalViewCache(capacity: 0))
        let abandoned = store(first, in: TerminalViewCache())
        let references = [evicted, replaced, pruned, cleared, rejected, abandoned]
        await eventually { references.allSatisfy { $0.value == nil } }
    }

    func testDifferentHerdOrAgentCannotReuseTerminal() {
        let cache = TerminalViewCache()
        let original = key("pane")
        cache.store(surface(), for: original)
        XCTAssertNil(cache.take(key("pane")))
        XCTAssertNil(cache.take(TerminalCacheKey(
            scope: original.scope, paneID: original.paneID,
            terminalID: original.terminalID, agentSessionID: "new-agent"
        )))
        cache.retain([])
        XCTAssertEqual(cache.count, 0)
    }

    func testOnlyOuterViewCanMoveGridHorizontally() {
        let surface = surface()
        surface.scroll.frame.size.width = 390
        surface.scroll.contentSize.width = 650
        surface.scroll.contentOffset.x = 120
        surface.terminal.contentOffset.x = 90
        surface.terminal.setContentOffset(CGPoint(x: 75, y: 0), animated: false)
        surface.terminal.receiveFrame(
            Data("\u{1B}[Hleft edge".utf8), full: true, grid: PaneGridSize(cols: 80, rows: 4)
        )
        surface.terminal.frame.size.width = 800
        surface.terminal.layoutIfNeeded()
        XCTAssertEqual(surface.terminal.contentOffset.x, 0, "Nested scrolling must not crop the left columns")
        XCTAssertEqual(surface.scroll.contentOffset.x, 120, "Keep the user's horizontal position")
        surface.scroll.contentOffset.x = 0
        XCTAssertEqual(surface.terminal.convert(.zero, to: surface.scroll).x, 0)
    }

    func testSwiftUINavigationRestoresSameTerminalAndSendsConditionalRead() async throws {
        var messages: [BridgeMessage] = []
        let connection = BridgeConnection(messageSender: { messages.append($0) })
        connection.finishAuthentication(protocolVersion: bridgeProtocolVersion, sessionName: "test-herd")
        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data("""
        {"version":"test","protocol":1,"layouts":[],"panes":[{"pane_id":"pane","terminal_id":"term","workspace_id":"w",
        "tab_id":"t","focused":true,"cwd":"/test","agent":"codex",
        "agent_status":"idle","revision":1}],"workspaces":[],"tabs":[]}
        """.utf8))
        connection.replaceWithLiveSnapshot(snapshot)
        let pane = try XCTUnwrap(snapshot.panes.first)
        let thread = AnyView(NavigationStack {
            PaneTerminalView(pane: pane, connection: connection)
        }.preferredColorScheme(.dark))
        let host = UIHostingController(rootView: thread)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
            connection.disconnect()
        }
        try await Task.sleep(for: .milliseconds(100))
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        await eventually {
            messages.contains { if case .readScrollback = $0 { return true }; return false }
        }
        let terminal = try XCTUnwrap(terminal(in: host.view))
        let history = Data("older line\n".utf8)
        connection.handle(.scrollback(paneID: "pane", bytesBase64: history.base64EncodedString()))
        connection.handle(.paneFrame(
            paneID: "pane", bytesBase64: Data("\u{1B}[Hidle thread".utf8).base64EncodedString(),
            full: true, seq: 1, cols: 80, rows: 24
        ))
        let cells = terminal.getTerminal().getBufferAsData()
        XCTAssertTrue(String(decoding: cells, as: UTF8.self).contains("older line"))
        messages.removeAll()
        host.rootView = AnyView(Color.clear)
        await eventually {
            connection.terminalViewCache.count == 1
                && messages.contains { if case .detachStream = $0 { return true }; return false }
        }
        XCTAssertEqual(connection.terminalViewCache.count, 1)
        XCTAssertTrue(messages.contains { if case .detachStream = $0 { return true }; return false })

        messages.removeAll()
        host.rootView = thread
        await eventually {
            messages.contains { if case .readScrollback = $0 { return true }; return false }
        }
        let returned = try XCTUnwrap(self.terminal(in: host.view))
        XCTAssertTrue(returned === terminal, "Returning must reuse the rendered terminal")
        XCTAssertEqual(returned.getTerminal().getBufferAsData(), cells, "Cached content appears before any reply")
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        })
        attachment.name = "Cached thread before network reply"
        attachment.lifetime = .keepAlways
        add(attachment)
        let hashes = messages.compactMap { message -> String? in
            if case let .readScrollback(_, _, _, _, knownHash) = message { return knownHash }
            return nil
        }
        XCTAssertEqual(hashes, [PaneScrollback.contentHash(history)])
        connection.handle(.scrollbackUnchanged(paneID: "pane", contentHash: hashes.first ?? ""))
        XCTAssertEqual(returned.getTerminal().getBufferAsData(), cells)

        // The navigation destination stays open while its underlying terminal changes.
        let replacementJSON = try JSONEncoder().encode(snapshot)
        let replacement = try JSONDecoder().decode(SessionSnapshot.self, from: Data(
            String(decoding: replacementJSON, as: UTF8.self)
                .replacingOccurrences(of: "\"term\"", with: "\"replacement\"").utf8
        ))
        messages.removeAll()
        connection.replaceWithLiveSnapshot(replacement)
        host.rootView = AnyView(NavigationStack {
            PaneTerminalView(pane: replacement.panes[0], connection: connection)
        }.preferredColorScheme(.dark))
        await eventually {
            messages.contains { if case .attachStream = $0 { return true }; return false }
        }
        let newTerminal = try XCTUnwrap(self.terminal(in: host.view))
        XCTAssertFalse(newTerminal === returned)
        XCTAssertTrue(messages.contains { if case .readScrollback = $0 { return true }; return false })
        XCTAssertTrue(messages.contains { if case .attachStream = $0 { return true }; return false })
        connection.handle(.scrollback(paneID: "pane", bytesBase64: ""))
        connection.handle(.paneFrame(
            paneID: "pane", bytesBase64: Data("\u{1B}[Hnew terminal".utf8).base64EncodedString(),
            full: true, seq: 1, cols: 80, rows: 24
        ))
        XCTAssertTrue(newTerminal.liveGridText().contains("new terminal"))
        XCTAssertFalse(String(decoding: newTerminal.getTerminal().getBufferAsData(), as: UTF8.self)
            .contains("older line"))
    }

    private func terminal(in view: UIView) -> GridReadableTerminalView? {
        if let terminal = view as? GridReadableTerminalView { return terminal }
        return view.subviews.lazy.compactMap { self.terminal(in: $0) }.first
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }
}
