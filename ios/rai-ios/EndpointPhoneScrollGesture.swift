import Combine
import RaiCore
import SwiftTerm
import UIKit

@MainActor
final class EndpointPhoneScrollGesture: NSObject, UIGestureRecognizerDelegate {
    private weak var terminal: TerminalView?
    private weak var model: EndpointPhoneModel?
    private var target: EndpointSurfacePane?
    private var targetIdentity: EndpointViewIdentity?
    private var targetBoot: String?
    private var targetPopupID: String?
    private var startPoint = CGPoint.zero
    private var sentMouseLines = 0
    private var stateSubscription: AnyCancellable?

    init(terminal: TerminalView, model: EndpointPhoneModel) {
        self.terminal = terminal
        self.model = model
        super.init()
        stateSubscription = model.$state.combineLatest(model.$identity).sink { [weak self] state, identity in
            guard let self, let target else { return }
            if targetIdentity != identity || targetBoot != state?.surface?.bootID
                || targetPopupID != state?.surface?.popup?.terminalID
                || (targetPopupID == nil && state?.surface?.panes.contains(where: { $0.paneID == target.paneID }) != true) {
                self.target = nil
            }
        }
        let pan = UIPanGestureRecognizer(target: self, action: #selector(scroll(_:)))
        pan.maximumNumberOfTouches = 1
        pan.allowedScrollTypesMask = .all
        pan.delegate = self
        terminal.addGestureRecognizer(pan)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let terminal, terminal.getSelectionRange() == nil,
              let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
        let velocity = pan.velocity(in: terminal)
        return abs(velocity.y) > abs(velocity.x)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        Self.isNativePan(otherGestureRecognizer)
    }

    static func isNativePan(_ recognizer: UIGestureRecognizer) -> Bool {
        recognizer is UIPanGestureRecognizer && !(recognizer.delegate is EndpointPhoneScrollGesture)
            && !(recognizer.delegate is EndpointPhoneMouseGesture)
    }

    @objc func scroll(_ pan: UIPanGestureRecognizer) {
        defer {
            if [.ended, .cancelled, .failed].contains(pan.state) {
                target = nil; targetIdentity = nil; targetBoot = nil; targetPopupID = nil
                startPoint = .zero; sentMouseLines = 0
            }
        }
        guard let terminal, let model, let surface = model.state?.surface else { return }
        let frame = terminal.getOptimalFrameSize()
        let cellWidth = frame.width / CGFloat(max(1, surface.grid.width))
        let cellHeight = frame.height / CGFloat(max(1, surface.grid.height))
        guard cellWidth > 0, cellHeight > 0 else { return }
        if pan.state == .began {
            targetIdentity = model.identity
            targetBoot = surface.bootID
            targetPopupID = surface.popup?.terminalID
            let point = pan.location(in: terminal)
            let translation = pan.translation(in: terminal)
            // Recognition starts after movement. Keep the pane where the touch began.
            startPoint = CGPoint(x: point.x - translation.x, y: point.y - translation.y)
            let column = startPoint.x / cellWidth
            let row = startPoint.y / cellHeight
            target = surface.panes.first {
                column >= CGFloat($0.innerRect.x) && column < CGFloat($0.innerRect.x) + CGFloat($0.innerRect.width)
                    && row >= CGFloat($0.innerRect.y) && row < CGFloat($0.innerRect.y) + CGFloat($0.innerRect.height)
            }
            sentMouseLines = 0
        }
        guard targetIdentity == model.identity, targetBoot == surface.bootID, let target else { return }
        if pan.state == .began || pan.state == .changed || pan.state == .ended {
            let lines = Int(pan.translation(in: terminal).y / cellHeight)
            if surface.popup?.mouseReporting ?? (target.mouseReporting || target.alternateScreen) {
                if sendMouseScroll(lines: lines, surface: surface, terminal: terminal, paneID: target.paneID) { return }
            }
            if let metrics = target.scroll {
                let offset = EndpointScroll.offset(from: metrics.offset, lines: lines, maximum: metrics.maximum)
                model.scroll(paneID: target.paneID, offset: offset)
            }
        }
    }

    private func sendMouseScroll(lines: Int, surface: HerdrEndpointSurface, terminal: TerminalView, paneID: String) -> Bool {
        let delta = lines - sentMouseLines
        guard delta != 0 else { return true }
        let kind: EndpointMouse.Kind = delta > 0 ? .scrollUp : .scrollDown
        let count = min(abs(delta), 120)
        guard let mouseTarget = Self.mouseTarget(at: startPoint, surface: surface, terminal: terminal,
                                                 kind: kind, lines: UInt16(count)),
              surface.popup != nil || mouseTarget.paneID == paneID else { return false }
        model?.wheel(mouseTarget.input)
        sentMouseLines += delta > 0 ? count : -count
        return true
    }

    static func mouseTarget(at point: CGPoint, surface: HerdrEndpointSurface, terminal: TerminalView,
                            kind: EndpointMouse.Kind, button: EndpointMouse.Button? = nil,
                            lines: UInt16 = 1) -> EndpointMouseTarget? {
        let size = terminal.getOptimalFrameSize()
        guard size.width > 0, size.height > 0 else { return nil }
        return surface.mouse(atColumn: Double(point.x) * Double(surface.grid.width) / size.width,
                             row: Double(point.y) * Double(surface.grid.height) / size.height,
                             kind: kind, button: button, lines: lines)
    }
}
