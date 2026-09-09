import Combine
import RaiCore
import SwiftTerm
import UIKit

@MainActor
final class EndpointPhoneMouseGesture: NSObject, UIGestureRecognizerDelegate {
    private weak var terminal: TerminalView?
    private weak var model: EndpointPhoneModel?
    private var dragCapture: EndpointMouseCapture?
    private var dragIdentity: EndpointViewIdentity?
    private var stateSubscription: AnyCancellable?

    init(terminal: TerminalView, model: EndpointPhoneModel) {
        self.terminal = terminal; self.model = model
        super.init()
        stateSubscription = model.$state.combineLatest(model.$identity).sink { [weak self] state, identity in
            guard let self else { return }
            dragCapture?.observe(dragIdentity == identity ? state?.surface : nil)
        }
        let tap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        pan.maximumNumberOfTouches = 1
        tap.require(toFail: pan)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hover(_:)))
        for recognizer in [tap, pan, hover] as [UIGestureRecognizer] {
            recognizer.delegate = self
            terminal.addGestureRecognizer(recognizer)
        }
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let surface = model?.state?.surface, let terminal, terminal.getSelectionRange() == nil else { return false }
        return target(recognizer.location(in: terminal), surface: surface, kind: .moved) != nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer is UIPanGestureRecognizer && EndpointPhoneScrollGesture.isNativePan(otherGestureRecognizer)
    }

    @objc private func tap(_ recognizer: UITapGestureRecognizer) {
        guard let surface = model?.state?.surface, let terminal else { return }
        let point = recognizer.location(in: terminal)
        send(point, surface: surface, kind: .down, button: .left)
        send(point, surface: surface, kind: .up, button: .left)
    }

    @objc private func hover(_ recognizer: UIHoverGestureRecognizer) {
        guard recognizer.state == .changed, let surface = model?.state?.surface, let terminal else { return }
        send(recognizer.location(in: terminal), surface: surface, kind: .moved)
    }

    @objc private func pan(_ recognizer: UIPanGestureRecognizer) {
        let finished = [.ended, .cancelled, .failed].contains(recognizer.state)
        defer {
            if finished { dragCapture = nil; dragIdentity = nil }
        }
        guard let model, let terminal, let surface = model.state?.surface else { return }
        let point = recognizer.location(in: terminal)
        if recognizer.state == .began {
            guard model.acceptsInput else { return }
            dragIdentity = model.identity
            let translation = recognizer.translation(in: terminal)
            let start = CGPoint(x: point.x - translation.x, y: point.y - translation.y)
            guard let down = target(start, surface: surface, kind: .down, button: .left) else { return }
            dragCapture = EndpointMouseCapture(target: down, surface: surface)
            model.input(.mouse(down.input))
        }
        guard dragIdentity == model.identity, model.acceptsInput else { dragCapture?.observe(nil); return }
        if finished {
            if let release = dragCapture?.release(in: surface) { model.input(.mouse(release.input)) }
        } else if let next = target(point, surface: surface, kind: .drag, button: .left),
                  let drag = dragCapture?.drag(next, in: surface) {
            model.input(.mouse(drag.input))
        }
    }

    private func send(_ point: CGPoint, surface: HerdrEndpointSurface, kind: EndpointMouse.Kind,
                      button: EndpointMouse.Button? = nil) {
        guard let target = target(point, surface: surface, kind: kind, button: button) else { return }
        model?.input(.mouse(target.input))
    }

    private func target(_ point: CGPoint, surface: HerdrEndpointSurface, kind: EndpointMouse.Kind,
                        button: EndpointMouse.Button? = nil) -> EndpointMouseTarget? {
        guard let size = terminal?.getOptimalFrameSize(), size.width > 0, size.height > 0 else { return nil }
        return surface.mouse(atColumn: Double(point.x) * Double(surface.grid.width) / size.width,
                             row: Double(point.y) * Double(surface.grid.height) / size.height,
                             kind: kind, button: button)
    }
}
