import Foundation
import RaiCore
import SwiftTerm
import UIKit
import XCTest
@testable import rai

@MainActor
final class EndpointPhoneModelTests: XCTestCase {
    private func state(_ model: EndpointPhoneModel, sequence: UInt64 = 1, boot: String = "boot") throws -> EndpointBridgeState {
        let snapshot = try JSONDecoder().decode(HerdrEndpointSnapshot.self,
            from: JSONSerialization.data(withJSONObject: ["boot_id": boot, "revision": 1, "focused_pane_id": "w1:p1"]))
        return EndpointBridgeState(identity: try XCTUnwrap(model.identity), sequence: sequence,
            snapshot: snapshot, surface: nil, methods: ["pane.focus"], busy: false, error: nil)
    }

    func testPluginPaneLaunchRequiresAdvertisedMethodAndUsesCurrentViewIdentity() async throws {
        let model = EndpointPhoneModel()
        defer { model.disconnect() }
        var requests: [EndpointBridgeRequest] = []
        model.open(connectionID: "phone-owner") { requests.append($0) }
        let current = try state(model)
        model.receive(current)
        let plugin = try XCTUnwrap(EndpointInstalledPlugin(.object(["plugin_id": .string("p"), "name": .string("P"),
            "enabled": .bool(true), "panes": .array([.object(["id": .string("popup"), "title": .string("Popup")])])])))
        let invocation = try XCTUnwrap(EndpointPluginPaneInvocation(plugin: plugin, pane: try XCTUnwrap(plugin.panes.first),
            snapshot: try XCTUnwrap(current.snapshot)))
        let request = EndpointPluginRequest(bootID: "boot", operation: .openPane(invocation))
        XCTAssertFalse(model.performPlugin(request))
        model.receive(.init(identity: current.identity, sequence: 1, snapshot: current.snapshot,
            surface: nil, methods: ["plugin.pane.open"], busy: false, error: nil))
        XCTAssertTrue(model.performPlugin(request))
        for _ in 0..<20 { await Task.yield() }
        let sent = try XCTUnwrap(requests.first { if case .plugin = $0.operation { return true }; return false })
        XCTAssertEqual(sent.identity, model.identity)
        XCTAssertEqual(sent.operation, .plugin(request))
        model.disconnect()
        XCTAssertFalse(model.performPlugin(request))
    }

    func testAgentLaunchKeepsMachineViewAndRejectsAChangedView() async throws {
        let model = EndpointPhoneModel()
        var requests: [EndpointBridgeRequest] = []
        let machine = MachineEndpoint(profileID: String(repeating: "a", count: 32), session: "remote")
        model.open(connectionID: "remote-connection", machineEndpoint: machine) { requests.append($0) }
        let identity = try XCTUnwrap(model.identity)
        let snapshot = try JSONDecoder().decode(HerdrEndpointSnapshot.self, from: Data(
            #"{"boot_id":"boot","revision":1,"panes":[{"pane_id":"w1:p1"}]}"#.utf8))
        model.receive(.init(identity: identity, sequence: 1, snapshot: snapshot, surface: nil,
            methods: [], busy: false, error: nil))
        let launch = EndpointAgentLaunchRequest(bootID: "boot", owningViewID: identity.viewID,
            paneID: "w1:p1", name: "codex", kind: .codex)
        XCTAssertFalse(model.launchAgent(.init(bootID: "boot", owningViewID: UUID(),
            paneID: "w1:p1", name: "codex", kind: .codex)))
        XCTAssertTrue(model.launchAgent(launch))
        for _ in 0..<20 { await Task.yield() }
        let sent = try XCTUnwrap(requests.first { if case .launchAgent = $0.operation { return true }; return false })
        XCTAssertEqual(sent.identity, identity)
        XCTAssertEqual(sent.identity.machineEndpoint, machine)
        XCTAssertEqual(sent.operation, .launchAgent(launch))
        model.disconnect()
        XCTAssertFalse(model.launchAgent(launch))
    }

    func testInitialResizeIsRetainedAndRepeatedSizesAreCoalesced() async throws {
        let model = EndpointPhoneModel()
        var requests: [EndpointBridgeRequest] = []
        model.resize(columns: 48, rows: 30)
        model.open(connectionID: "mac") { requests.append($0) }
        model.resize(columns: 60, rows: 35)
        model.receive(try state(model))
        model.resize(columns: 60, rows: 35)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(requests.map(\.operation), [.open(columns: 48, rows: 30), .resize(columns: 60, rows: 35)])
        XCTAssertEqual(requests.map(\.sequence), [1, 2])
        XCTAssertEqual(requests.last?.bootID, "boot")
        model.disconnect()
    }

    func testMachineSwitchDropsQueuedActionsAndRejectsDuplicatePaneHistoryAndImages() async throws {
        let model = EndpointPhoneModel()
        defer { model.disconnect() }
        let one = MachineEndpoint(profileID: String(repeating: "a", count: 32), session: "default")
        let two = MachineEndpoint(profileID: String(repeating: "b", count: 32), session: "default")
        var oldRequests: [EndpointBridgeRequest] = [], currentRequests: [EndpointBridgeRequest] = []
        model.open(connectionID: "same-connection", machineEndpoint: one) { oldRequests.append($0) }
        let key: [String: Any] = ["source": ["pane": ["_0": "w1:p1", "_1": 1]],
            "width": 1, "height": 1, "format": 0, "byteCount": 3, "fingerprint": 1]
        let image: [String: Any] = ["key": key, "data": Data([255, 0, 0]).base64EncodedString()]
        let scene = try JSONDecoder().decode(EndpointGraphicsScene.self, from: JSONSerialization.data(withJSONObject:
            ["assets": [image], "placements": [], "retained": [key]]))
        var first = try state(model)
        first.surface = try renderedSurface(); first.surface?.graphics = scene
        first.terminalResult = .init(requestID: UUID(), text: "machine one private history")
        model.receive(first)
        XCTAssertEqual(model.state?.surface?.graphics.assets.count, 1)
        model.input(.text("old queued input")); model.close()
        model.open(connectionID: "same-connection", machineEndpoint: two) { currentRequests.append($0) }
        XCTAssertNil(model.state)
        var second = try state(model)
        second.surface = try renderedSurface()
        second.surface?.graphics = scene.excludingAssets(Set(scene.assets.map(\.key)))
        second.terminalResult = .init(requestID: UUID(), text: "machine two history")
        model.receive(second)
        let currentIdentity = try XCTUnwrap(model.identity)
        let foreignIdentity = EndpointViewIdentity(connectionID: currentIdentity.connectionID,
            viewID: currentIdentity.viewID, machineEndpoint: one)
        var foreign = EndpointBridgeState(identity: foreignIdentity, sequence: 1, snapshot: first.snapshot,
            surface: first.surface, methods: first.methods, busy: false, error: nil)
        foreign.terminalResult = first.terminalResult
        model.receive(foreign)
        XCTAssertEqual(model.state?.terminalResult?.text, "machine two history")
        XCTAssertTrue(try XCTUnwrap(model.state?.surface?.graphics.assets).isEmpty,
            "A matching pane and image key cannot recover another machine's cached image.")
        XCTAssertTrue(model.acceptsInput)
        model.input(.text("current input"))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(oldRequests.isEmpty, "Switching machines cancels queued input and close requests.")
        XCTAssertEqual(currentRequests.map(\.operation), [
            .open(columns: 80, rows: 32), .input(paneID: "w1:p1", input: .text("current input"))])
        model.close()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(currentRequests.last?.operation, .close)
        XCTAssertTrue(currentRequests.allSatisfy { $0.identity == currentIdentity })
    }

    func testWrongViewFutureSequenceAndRestartCannotEnableInput() throws {
        let model = EndpointPhoneModel()
        model.open(connectionID: "mac") { _ in }
        let other = EndpointBridgeState(identity: EndpointViewIdentity(connectionID: "mac"), sequence: 1,
            snapshot: nil, surface: nil, methods: [], busy: false, error: nil)
        model.receive(other)
        XCTAssertNil(model.state)
        model.receive(try state(model, sequence: 2))
        XCTAssertNil(model.state)
        model.receive(try state(model))
        XCTAssertNotNil(model.state)
        XCTAssertFalse(model.acceptsInput, "Metadata without matching rendered content cannot accept input")
        model.receive(try state(model, boot: "restarted"))
        XCTAssertTrue(model.error?.contains("restarted") == true)
        XCTAssertFalse(model.acceptsInput)
        model.disconnect()
    }

    func testDisconnectDropsQueuedWorkAndOldErrors() async throws {
        let model = EndpointPhoneModel()
        var sent = 0
        model.open(connectionID: "mac") { _ in sent += 1 }
        let oldID = try XCTUnwrap(model.identity)
        model.receive(try state(model))
        model.command(.focusPane("w1:p2"))
        model.disconnect()
        model.open(connectionID: "mac") { _ in sent += 1 }
        model.receiveError("old error", requestID: oldID.viewID.uuidString + ":1")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(sent, 1)
        XCTAssertNil(model.error)
        XCTAssertNotEqual(model.identity, oldID)
        model.close()
        XCTAssertFalse(model.acceptsInput)
        model.disconnect()
    }

    func testSendFailureDropsFollowingWritesAndCannotBeClearedByLateState() async throws {
        let model = EndpointPhoneModel()
        var requests: [EndpointBridgeRequest] = []
        model.open(connectionID: "mac") { request in
            requests.append(request)
            throw URLError(.networkConnectionLost)
        }
        let initial = try state(model)
        model.receive(initial)
        model.resize(columns: 60, rows: 30)
        model.command(.focusPane("w1:p2"))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(requests.count, 1)
        let failure = model.error
        XCTAssertNotNil(failure)
        model.receive(initial)
        XCTAssertEqual(model.error, failure)
        model.disconnect()
    }

    func testQueueLimitDiscardsPendingWork() throws {
        let model = EndpointPhoneModel()
        model.open(connectionID: "mac") { _ in XCTFail("Overflow must stop queued writes") }
        model.receive(try state(model))
        for columns in 1...70 { model.resize(columns: columns, rows: 30) }
        XCTAssertTrue(model.error?.contains("queue is full") == true)
        XCTAssertFalse(model.acceptsInput)
        model.disconnect()
    }

    func testCloseCannotBeReopenedByAnInFlightState() throws {
        let model = EndpointPhoneModel()
        model.open(connectionID: "mac") { _ in }
        let initial = try state(model)
        model.receive(initial)
        model.close()
        model.receive(initial)
        XCTAssertEqual(model.error, "Workspace view closed.")
        XCTAssertFalse(model.acceptsInput)
        model.disconnect()
    }

    func testRepeatedCloseSendsOnceAndNewViewCanClose() async throws {
        let model = EndpointPhoneModel()
        var requests: [EndpointBridgeRequest] = []
        model.open(connectionID: "mac") { requests.append($0) }
        for _ in 0..<20 { await Task.yield() }
        let first = try XCTUnwrap(model.identity)
        model.close()
        for _ in 0..<20 { await Task.yield() }
        model.close()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(requests.map(\.operation), [.open(columns: 80, rows: 32), .close])
        XCTAssertFalse(model.acceptsInput)

        model.open(connectionID: "mac") { requests.append($0) }
        for _ in 0..<20 { await Task.yield() }
        model.close()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(requests.filter { $0.operation == .close }.count, 2)
        XCTAssertNotEqual(requests.last?.identity, first)
        model.disconnect()
    }

    func testInputKeepsPaneAndBootIdentityAndWaitsForNavigation() async throws {
        let model = EndpointPhoneModel()
        var sent: [EndpointBridgeRequest] = []
        model.open(connectionID: "mac") { sent.append($0) }
        let initial = try state(model)
        let surface = try renderedSurface()
        model.receive(EndpointBridgeState(identity: initial.identity, sequence: 1, snapshot: initial.snapshot,
            surface: surface, methods: initial.methods, busy: false, error: nil))
        XCTAssertTrue(model.acceptsInput)
        model.input(.paste("one\ntwo"))
        model.input(.special(.enter, modifiers: 0))
        model.command(.focusPane("w1:p2"))
        model.input(.text("must not reach old pane"))
        XCTAssertFalse(model.acceptsInput)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(sent.map(\.sequence), [1, 2, 3, 4])
        XCTAssertEqual(sent[1].operation, .input(paneID: "w1:p1", input: .paste("one\ntwo")))
        XCTAssertEqual(sent[2].operation, .input(paneID: "w1:p1", input: .special(.enter, modifiers: 0)))
        XCTAssertEqual(sent[1].bootID, "boot")
        XCTAssertEqual(sent[1].projectionRevision, 1)
        model.disconnect()
    }
    func testScrollKeepsLatestTargetUntilTheServerCompletesItsRequest() async throws {
        let model = EndpointPhoneModel()
        var requests: [EndpointBridgeRequest] = []
        model.open(connectionID: "mac") { requests.append($0) }
        let initial = try state(model)
        let surface = try renderedSurface()
        func reply(_ sequence: UInt64, busy: Bool = false) -> EndpointBridgeState {
            EndpointBridgeState(identity: initial.identity, sequence: sequence, snapshot: initial.snapshot,
                surface: surface, methods: ["pane.scroll"], busy: busy, error: nil)
        }
        model.receive(reply(1))
        model.scroll(paneID: "w1:p1", offset: 10)
        model.scroll(paneID: "w1:p1", offset: 20)
        model.scroll(paneID: "w1:p1", offset: 30)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].operation, .command(.scroll(paneID: "w1:p1", offset: 10)))
        model.receive(reply(2, busy: true))
        XCTAssertTrue(model.busy)
        model.receive(reply(2))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[2].operation, .command(.scroll(paneID: "w1:p1", offset: 30)))
        model.disconnect()
        model.receive(reply(3))
        XCTAssertNil(model.state)
        XCTAssertTrue(model.scrollActivity.isEmpty)
    }

    func testHistoryDragKeepsItsStartingPaneAndRejectsSelection() async throws {
        let model = EndpointPhoneModel()
        var requests: [EndpointBridgeRequest] = []
        model.open(connectionID: "mac") { requests.append($0) }
        let initial = try state(model)
        model.receive(EndpointBridgeState(identity: initial.identity, sequence: 1, snapshot: initial.snapshot,
            surface: try renderedSurface(), methods: ["pane.scroll"], busy: false, error: nil))
        let terminal = EndpointPhoneTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        terminal.pinGridSize(cols: 1, rows: 1)
        terminal.isScrollEnabled = false
        let gesture = EndpointPhoneScrollGesture(terminal: terminal, model: model)
        let pan = HistoryTestPan()
        let cell = terminal.getOptimalFrameSize()
        pan.movement = CGPoint(x: 0, y: cell.height * 5)
        pan.point = CGPoint(x: cell.width / 2, y: cell.height * 5.5)
        XCTAssertTrue(gesture.gestureRecognizerShouldBegin(pan))
        pan.phase = .began
        gesture.scroll(pan)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(requests.last?.operation, .command(.scroll(paneID: "w1:p1", offset: 5)))
        terminal.setSelectionRange(start: Position(col: 0, row: 0), end: Position(col: 1, row: 0))
        XCTAssertFalse(gesture.gestureRecognizerShouldBegin(pan))
        terminal.selectNone()
        pan.movement = CGPoint(x: 50, y: 1)
        XCTAssertFalse(gesture.gestureRecognizerShouldBegin(pan))
        model.disconnect()
    }

    func testSemanticPansTakePriorityOverNativeCursorPanWithoutBlockingSelection() {
        let model = EndpointPhoneModel()
        let terminal = EndpointPhoneTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let scroll = EndpointPhoneScrollGesture(terminal: terminal, model: model)
        let mouse = EndpointPhoneMouseGesture(terminal: terminal, model: model)
        let native = UIPanGestureRecognizer()
        let scrollPan = UIPanGestureRecognizer(); scrollPan.delegate = scroll
        let mousePan = UIPanGestureRecognizer(); mousePan.delegate = mouse
        XCTAssertTrue(scroll.gestureRecognizer(scrollPan, shouldBeRequiredToFailBy: native))
        XCTAssertTrue(mouse.gestureRecognizer(mousePan, shouldBeRequiredToFailBy: native))
        XCTAssertFalse(scroll.gestureRecognizer(scrollPan, shouldBeRequiredToFailBy: mousePan))
        XCTAssertFalse(mouse.gestureRecognizer(mousePan, shouldBeRequiredToFailBy: scrollPan))
        XCTAssertFalse(mouse.gestureRecognizer(UITapGestureRecognizer(), shouldBeRequiredToFailBy: native))
        terminal.setSelectionRange(start: Position(col: 0, row: 0), end: Position(col: 1, row: 0))
        XCTAssertFalse(scroll.gestureRecognizerShouldBegin(scrollPan))
        XCTAssertFalse(mouse.gestureRecognizerShouldBegin(mousePan))
        XCTAssertNotNil(terminal.getSelectionRange())
    }

    private func renderedSurface() throws -> HerdrEndpointSurface {
        try EndpointPhoneTestSurface.make()
    }

}

@MainActor
private final class HistoryTestPan: UIPanGestureRecognizer {
    var phase: UIGestureRecognizer.State = .possible
    var point = CGPoint.zero
    var movement = CGPoint.zero
    override var state: UIGestureRecognizer.State { get { phase } set { phase = newValue } }
    override func location(in view: UIView?) -> CGPoint { point }
    override func translation(in view: UIView?) -> CGPoint { movement }
    override func velocity(in view: UIView?) -> CGPoint { movement }
}
