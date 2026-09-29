import RaiCore
import SwiftTerm
import UIKit

/// Swipes over an alternate-screen application send semantic wheel input.
@MainActor
final class PaneTerminalScrollGesture: NSObject, UIGestureRecognizerDelegate {
    private static let flingVelocityThreshold: CGFloat = 240
    private static let flingProjection: CGFloat = 0.18
    private static let maximumFlingLines = 60

    private weak var view: GridReadableTerminalView?
    private var origin: CGPoint?
    private var grid: PaneGridSize?
    private var identity: EndpointViewIdentity?
    private var bootID: String?
    private var target: EndpointSurfacePane?
    private var sentLines = 0

    init(terminal: GridReadableTerminalView) {
        view = terminal
        super.init()
        let pan = UIPanGestureRecognizer(target: self, action: #selector(scroll(_:)))
        pan.maximumNumberOfTouches = 1
        pan.allowedScrollTypesMask = .all
        pan.delegate = self
        terminal.addGestureRecognizer(pan)
        terminal.panGestureRecognizer.require(toFail: pan)
        (terminal.superview as? UIScrollView)?.panGestureRecognizer.require(toFail: pan)
    }

    private var canSendWheel: Bool {
        guard let view else { return false }
        guard view.hasLiveFrame, view.getSelectionRange() == nil,
              let model = view.scrollModel, model.acceptsWheelInput, let surface = model.state?.surface,
              surface.popup == nil, let pane = surface.panes.first(where: { $0.paneID == view.scrollPaneID }) else { return false }
        return pane.focused && (pane.mouseReporting || pane.alternateScreen)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard canSendWheel, let view,
              let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
        let velocity = pan.velocity(in: view)
        let terminal = view.getTerminal()
        return abs(velocity.y) > abs(velocity.x) && terminal.buffer.yDisp >= view.liveGridStartRow
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        otherGestureRecognizer is UIPanGestureRecognizer
    }

    func scrollPage(up: Bool) -> Bool {
        guard canSendWheel, let view, let model = view.scrollModel,
              let pane = model.state?.surface?.panes.first(where: { $0.paneID == view.scrollPaneID }),
              view.getTerminal().buffer.yDisp >= view.liveGridStartRow else { return false }
        sendWheel(up: up, lines: min(120, max(1, view.getTerminal().rows - 1)),
                  column: Int(pane.innerRect.width) / 2, row: Int(pane.innerRect.height) / 2, pane: pane, model: model)
        return true
    }

    private func sendWheel(up: Bool, lines: Int, column: Int, row: Int,
                           pane: EndpointSurfacePane, model: EndpointPhoneModel) {
        guard let target = model.state?.surface?.mouse(
            atColumn: Double(pane.innerRect.x) + Double(column) + 0.5,
            row: Double(pane.innerRect.y) + Double(row) + 0.5,
            kind: up ? .scrollUp : .scrollDown, lines: UInt16(lines)),
              target.paneID == pane.paneID else { return }
        model.wheel(target.input)
    }

    func cancel() {
        origin = nil
        grid = nil
        identity = nil
        bootID = nil
        target = nil
        sentLines = 0
    }

    @objc func scroll(_ pan: UIPanGestureRecognizer) {
        defer {
            if [.ended, .cancelled, .failed].contains(pan.state) { cancel() }
        }
        guard canSendWheel, let view, let model = view.scrollModel,
              let surface = model.state?.surface,
              let pane = surface.panes.first(where: { $0.paneID == view.scrollPaneID }) else { cancel(); return }
        let terminal = view.getTerminal()
        let currentGrid = PaneGridSize(cols: terminal.cols, rows: terminal.rows)
        let size = view.getOptimalFrameSize()
        let cellWidth = size.width / CGFloat(terminal.cols)
        let cellHeight = size.height / CGFloat(terminal.rows)
        guard cellWidth > 0, cellHeight > 0 else { return }
        if pan.state == .began {
            let point = pan.location(in: view)
            let translation = pan.translation(in: view)
            origin = CGPoint(x: point.x - translation.x,
                             y: point.y - translation.y - CGFloat(view.liveGridStartRow) * cellHeight)
            grid = currentGrid
            identity = model.identity
            bootID = surface.bootID
            target = pane
            sentLines = 0
        }
        guard [.began, .changed, .ended].contains(pan.state), let origin, grid == currentGrid,
              identity == model.identity, bootID == surface.bootID,
              target?.paneID == pane.paneID, target?.innerRect == pane.innerRect,
              target?.mouseReporting == pane.mouseReporting,
              target?.alternateScreen == pane.alternateScreen else { cancel(); return }
        let lines = Int(pan.translation(in: view).y / cellHeight)
        let delta = lines - sentLines
        let count = min(abs(delta), 120)
        let width = Int(pane.innerRect.width), height = Int(pane.innerRect.height)
        guard width > 0, height > 0 else { return }
        let column = max(0, min(width - 1, Int(origin.x / cellWidth)))
        let row = max(0, min(height - 1, Int(origin.y / cellHeight)))
        if delta != 0 {
            sendWheel(up: delta > 0, lines: count, column: column, row: row, pane: pane, model: model)
            sentLines += delta > 0 ? count : -count
        }
        guard pan.state == .ended else { return }
        let velocity = pan.velocity(in: view).y
        guard abs(velocity) >= Self.flingVelocityThreshold else { return }
        let projected = Int(velocity * Self.flingProjection / cellHeight)
        guard projected != 0 else { return }
        let fling = min(abs(projected), Self.maximumFlingLines)
        sendWheel(up: projected > 0, lines: fling, column: column, row: row, pane: pane, model: model)
    }
}
