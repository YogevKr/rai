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
        return EndpointPhoneScrollGesture.mouseTarget(at: recognizer.location(in: terminal), surface: surface,
                                                      terminal: terminal, kind: .moved) != nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer is UIPanGestureRecognizer else { return false }
        if otherGestureRecognizer.delegate is EndpointPhoneScrollGesture { return true }
        return EndpointPhoneScrollGesture.isNativePan(otherGestureRecognizer)
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
            guard let down = EndpointPhoneScrollGesture.mouseTarget(at: start, surface: surface, terminal: terminal,
                                                                     kind: .down, button: .left) else { return }
            dragCapture = EndpointMouseCapture(target: down, surface: surface)
            model.input(.mouse(down.input))
        }
        guard dragIdentity == model.identity, model.acceptsInput else { dragCapture?.observe(nil); return }
        if finished {
            if let release = dragCapture?.release(in: surface) { model.input(.mouse(release.input)) }
        } else if let next = EndpointPhoneScrollGesture.mouseTarget(at: point, surface: surface, terminal: terminal,
                                                                     kind: .drag, button: .left),
                  let drag = dragCapture?.drag(next, in: surface) {
            model.input(.mouse(drag.input))
        }
    }

    private func send(_ point: CGPoint, surface: HerdrEndpointSurface, kind: EndpointMouse.Kind,
                      button: EndpointMouse.Button? = nil) {
        guard let terminal else { return }
        guard let target = EndpointPhoneScrollGesture.mouseTarget(at: point, surface: surface, terminal: terminal,
                                                                  kind: kind, button: button) else { return }
        model?.input(.mouse(target.input))
    }
}
