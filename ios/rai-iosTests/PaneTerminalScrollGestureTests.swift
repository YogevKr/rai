import RaiCore
import SwiftTerm
import UIKit
import XCTest
@testable import rai

@MainActor
final class PaneTerminalScrollGestureTests: XCTestCase {
    private var window: UIWindow!
    private var view: GridReadableTerminalView!
    private var sink: WheelInputSink!
    private var gesture: PaneTerminalScrollGesture!
    private var pan: WheelTestPan!
    private var model: EndpointPhoneModel!
    private var requests: [EndpointBridgeRequest] = []
    private let grid = PaneGridSize(cols: 80, rows: 24)

    override func setUp() {
        super.setUp()
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        view = GridReadableTerminalView(frame: window.bounds)
        view.allowMouseReporting = false
        view.pinGridSize(cols: grid.cols, rows: grid.rows)
        window.addSubview(view)
        sink = WheelInputSink()
        view.terminalDelegate = sink
        gesture = view.gestureRecognizers?.compactMap { $0.delegate as? PaneTerminalScrollGesture }.first
        pan = WheelTestPan()
        model = EndpointPhoneModel()
        model.open(connectionID: "host") { [weak self] in self?.requests.append($0) }
        view.scrollModel = model
        view.scrollPaneID = "w1:p1"
        try! receiveSurface()
        frame("")
    }

    override func tearDown() {
        model.disconnect()
        model = nil
        requests = []
        window = nil
        view = nil
        sink = nil
        gesture = nil
        pan = nil
        super.tearDown()
    }

    private func frame(_ modes: String) {
        view.receiveFrame(Data(("\u{1B}[2J\u{1B}[Hscreen" + modes).utf8), kind: .full, grid: grid)
    }

    private func move(_ lines: CGFloat, state: UIGestureRecognizer.State) {
        let size = view.getOptimalFrameSize()
        let cellWidth = size.width / CGFloat(grid.cols)
        let cellHeight = size.height / CGFloat(grid.rows)
        pan.movement = CGPoint(x: 0, y: lines * cellHeight)
        pan.point = CGPoint(x: 5.5 * cellWidth, y: (2.5 + lines) * cellHeight)
        pan.phase = state
        gesture.scroll(pan)
    }

    private func receiveSurface(mouse: Bool = true, alternate: Bool = false,
                                paneID: String = "w1:p1", columns: Int = 80,
                                snapshotRevision: Int = 1, error: String? = nil) throws {
        let snapshot = try JSONDecoder().decode(HerdrEndpointSnapshot.self,
            from: JSONSerialization.data(withJSONObject: ["boot_id": "boot", "revision": snapshotRevision, "focused_pane_id": paneID]))
        model.receive(.init(identity: try XCTUnwrap(model.identity), sequence: 1,
            snapshot: snapshot, surface: try EndpointPhoneTestSurface.make(paneID: paneID,
                mouseReporting: mouse, alternateScreen: alternate, columns: columns, rows: 24),
            methods: ["pane.focus"], busy: false, error: error))
    }

    private func wheelInputs() async -> [EndpointMouse] {
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(sink.inputs.isEmpty, "Wheel input must never enter the text or bracketed-paste path")
        return requests.compactMap {
            guard case let .input(paneID, .mouse(mouse)) = $0.operation else { return nil }
            XCTAssertEqual(paneID, "w1:p1")
            return mouse
        }
    }

    func testSwipeSendsIncrementalWheelEventsAtItsStartingCell() async {
        move(2.5, state: .began)
        move(3.5, state: .changed)
        move(1.5, state: .changed)
        move(1.5, state: .ended)
        let inputs = await wheelInputs()
        XCTAssertEqual(inputs.map(\.kind), [.scrollUp, .scrollUp, .scrollDown])
        XCTAssertEqual(inputs.map(\.lines), [2, 1, 2])
        XCTAssertEqual(inputs.map(\.column), [5, 5, 5])
        XCTAssertEqual(inputs.map(\.row), [2, 2, 2])
        XCTAssertEqual(view.contentOffset, .zero, "Codex owns the movement")
    }

    func testShellHorizontalMovementAndSelectionKeepNativeGestures() {
        pan.movement = CGPoint(x: 0, y: 50)
        XCTAssertTrue(gesture.gestureRecognizerShouldBegin(pan))
        pan.movement = CGPoint(x: 50, y: 5)
        XCTAssertFalse(gesture.gestureRecognizerShouldBegin(pan))
        pan.movement = CGPoint(x: 0, y: 50)
        view.setSelectionRange(start: Position(col: 0, row: 0), end: Position(col: 3, row: 0))
        XCTAssertFalse(gesture.gestureRecognizerShouldBegin(pan))
        move(3, state: .began)
        XCTAssertTrue(sink.inputs.isEmpty)
        XCTAssertNotNil(view.getSelectionRange())
    }

    func testModeChangesWithoutTextChangesRestoreShellScrolling() throws {
        try receiveSurface(mouse: false)
        XCTAssertEqual(view.getTerminal().mouseMode, .off)
        pan.movement = CGPoint(x: 0, y: 50)
        XCTAssertFalse(gesture.gestureRecognizerShouldBegin(pan))
        XCTAssertTrue(view.panGestureRecognizer.isEnabled)
        move(3, state: .began)
        XCTAssertTrue(sink.inputs.isEmpty)
    }

    func testStaleSurfaceKeepsNativeScrolling() async throws {
        try receiveSurface(mouse: false, alternate: true, snapshotRevision: 0)
        pan.movement = CGPoint(x: 0, y: 50)
        XCTAssertFalse(gesture.gestureRecognizerShouldBegin(pan))
        XCTAssertFalse(gesture.scrollPage(up: true))
        move(3, state: .began)
        let inputs = await wheelInputs()
        XCTAssertTrue(inputs.isEmpty)
    }

    func testEndpointErrorKeepsNativeScrolling() async throws {
        try receiveSurface(mouse: false, alternate: true, error: "Connection failed")
        pan.movement = CGPoint(x: 0, y: 50)
        XCTAssertFalse(gesture.gestureRecognizerShouldBegin(pan))
        XCTAssertFalse(gesture.scrollPage(up: true))
        move(3, state: .began)
        let inputs = await wheelInputs()
        XCTAssertTrue(inputs.isEmpty)
    }

    func testReconnectCancelsTheSwipeUntilANewGesture() async {
        move(1, state: .began)
        view.awaitNextConnectionFrame()
        move(2, state: .changed)
        let inputCount1 = await wheelInputs().count
        XCTAssertEqual(inputCount1, 1)
        frame("\u{1B}[?1000h\u{1B}[?1006h")
        move(3, state: .changed)
        let inputCount2 = await wheelInputs().count
        XCTAssertEqual(inputCount2, 1)
        move(1, state: .began)
        let inputCount3 = await wheelInputs().count
        XCTAssertEqual(inputCount3, 2)
    }

    func testRepaintDuringSwipeKeepsTheGesture() async {
        move(1, state: .began)
        view.receiveFrame(Data("\u{1B}[Hupdated\u{1B}[?1000h".utf8), kind: .delta, grid: nil)
        move(2, state: .changed)
        let inputCount4 = await wheelInputs().count
        XCTAssertEqual(inputCount4, 2)
    }

    func testDetachingAndResizingDoNotSendStaleWheelInput() async {
        move(1, state: .began)
        view.suspendHistoryRefresh()
        move(2, state: .changed)
        let inputCount5 = await wheelInputs().count
        XCTAssertEqual(inputCount5, 1)
        move(1, state: .began)
        view.pinGridSize(cols: 100, rows: 30)
        move(2, state: .changed)
        let inputCount6 = await wheelInputs().count
        XCTAssertEqual(inputCount6, 2)
    }

    func testHistoryAboveTheLiveGridKeepsLocalScrolling() {
        view.receiveHistory(Data((0..<100).map { "history \($0)\r\n" }.joined().utf8))
        view.scrollTo(row: 0)
        pan.movement = CGPoint(x: 0, y: 50)
        XCTAssertGreaterThan(view.liveGridStartRow, 0)
        XCTAssertFalse(gesture.gestureRecognizerShouldBegin(pan))
    }

    func testAlternateScreenWithoutMouseModeUsesSemanticWheelInput() async throws {
        try receiveSurface(mouse: false, alternate: true)
        pan.movement = CGPoint(x: 0, y: 50)
        XCTAssertTrue(gesture.gestureRecognizerShouldBegin(pan))
        move(4, state: .began)
        let inputs = await wheelInputs()
        XCTAssertEqual(inputs.first?.lines, 4)
    }

    func testChangedPaneOrNativeGeometryCancelsGesture() async throws {
        move(1, state: .began)
        try receiveSurface(columns: 90)
        move(2, state: .changed)
        try receiveSurface()
        move(3, state: .changed)
        var inputs = await wheelInputs()
        XCTAssertEqual(inputs.count, 1)
        move(1, state: .began)
        try receiveSurface(paneID: "w1:p2")
        view.scrollPaneID = "w1:p2"
        move(2, state: .changed)
        inputs = await wheelInputs()
        XCTAssertEqual(inputs.count, 2)
    }

    func testGestureTakesPriorityOverNativePanOnlyWhenItCanBegin() {
        XCTAssertTrue(gesture.gestureRecognizer(pan, shouldBeRequiredToFailBy: view.panGestureRecognizer))
        XCTAssertFalse(gesture.gestureRecognizer(pan, shouldBeRequiredToFailBy: UILongPressGestureRecognizer()))
    }
}

@MainActor
private final class WheelTestPan: UIPanGestureRecognizer {
    var phase: UIGestureRecognizer.State = .possible
    var point = CGPoint.zero
    var movement = CGPoint.zero
    override var state: UIGestureRecognizer.State { get { phase } set { phase = newValue } }
    override func location(in view: UIView?) -> CGPoint { point }
    override func translation(in view: UIView?) -> CGPoint { movement }
    override func velocity(in view: UIView?) -> CGPoint { movement }
}

private final class WheelInputSink: TerminalViewDelegate {
    var inputs: [String] = []
    func send(source: TerminalView, data: ArraySlice<UInt8>) { inputs.append(String(decoding: data, as: UTF8.self)) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
