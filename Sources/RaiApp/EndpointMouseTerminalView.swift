import AppKit
import Combine
import RaiCore
import SwiftTerm

class EndpointMouseTerminalView: TerminalView {
    var endpointSurface: HerdrEndpointSurface? {
        didSet {
            for button in Array(pressed.keys) { pressed[button]?.observe(endpointSurface) }
        }
    }
    var semanticMouse: ((EndpointMouseTarget, HerdrEndpointSurface) -> Bool)?
    private var pointerMonitor: Any?
    private var surfaceSubscription: AnyCancellable?

    func observeMouseSurface(_ publisher: Published<HerdrEndpointSurface?>.Publisher) {
        surfaceSubscription = publisher.sink { [weak self] surface in self?.endpointSurface = surface }
    }
    private var pressed: [EndpointMouse.Button: EndpointMouseCapture] = [:]

    deinit { if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) } }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        pointerMonitor = nil
        guard window != nil else { return }
        pointerMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            guard let self, event.window === window, !isHiddenOrHasHiddenAncestor else { return event }
            _ = sendMouse(event, kind: .moved)
            return event
        }
    }

    override func mouseDown(with event: NSEvent) {
        if !sendMouse(event, kind: .down, button: .left) { super.mouseDown(with: event) }
    }
    override func mouseUp(with event: NSEvent) {
        if !sendMouse(event, kind: .up, button: .left) { super.mouseUp(with: event) }
    }
    override func mouseDragged(with event: NSEvent) {
        if !sendMouse(event, kind: .drag, button: .left) { super.mouseDragged(with: event) }
    }
    override func rightMouseDown(with event: NSEvent) {
        if !sendMouse(event, kind: .down, button: .right) { super.rightMouseDown(with: event) }
    }
    override func rightMouseUp(with event: NSEvent) {
        if !sendMouse(event, kind: .up, button: .right) { super.rightMouseUp(with: event) }
    }
    override func rightMouseDragged(with event: NSEvent) {
        if !sendMouse(event, kind: .drag, button: .right) { super.rightMouseDragged(with: event) }
    }
    override func otherMouseDown(with event: NSEvent) {
        if !sendMouse(event, kind: .down, button: .middle) { super.otherMouseDown(with: event) }
    }
    override func otherMouseUp(with event: NSEvent) {
        if !sendMouse(event, kind: .up, button: .middle) { super.otherMouseUp(with: event) }
    }
    override func otherMouseDragged(with event: NSEvent) {
        if !sendMouse(event, kind: .drag, button: .middle) { super.otherMouseDragged(with: event) }
    }
    func sendMouseWheel(_ event: NSEvent) -> Bool {
        let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
        guard delta != 0 else { return false }
        let kind: EndpointMouse.Kind
        if abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) { kind = delta > 0 ? .scrollUp : .scrollDown }
        else { kind = delta > 0 ? .scrollLeft : .scrollRight }
        return sendMouse(event, kind: kind, lines: UInt16(min(120, max(1, abs(delta)))))
    }

    private func sendMouse(_ event: NSEvent, kind: EndpointMouse.Kind,
                           button: EndpointMouse.Button? = nil, lines: UInt16 = 1) -> Bool {
        if kind == .up, let button {
            guard var capture = pressed.removeValue(forKey: button) else { return false }
            if let surface = endpointSurface, let release = capture.release(in: surface) {
                _ = semanticMouse?(release, surface)
            }
            return true
        }
        let captured = button.flatMap { pressed[$0] }
        if kind == .drag {
            guard let captured else { return false }
            guard captured.isValid else { return true }
        } else {
            if kind == .down, let button { pressed.removeValue(forKey: button) }
            // The initial modifiers keep native selection active for the complete gesture.
            guard !event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.command) else { return false }
        }
        guard let surface = endpointSurface, let semanticMouse else { return kind == .drag }
        let size = getOptimalFrameSize()
        guard size.width > 0, size.height > 0 else { return false }
        let point = convert(event.locationInWindow, from: nil)
        let row = Double(isFlipped ? point.y : bounds.height - point.y) * Double(surface.grid.height) / size.height
        let column = Double(point.x) * Double(surface.grid.width) / size.width
        var modifiers: UInt8 = 0
        if event.modifierFlags.contains(.shift) { modifiers |= 1 }
        if event.modifierFlags.contains(.command) { modifiers |= 8 }
        if event.modifierFlags.contains(.control) { modifiers |= 2 }
        if event.modifierFlags.contains(.option) { modifiers |= 4 }
        guard let target = surface.mouse(atColumn: column, row: row, kind: kind,
                                         button: button, modifiers: modifiers, lines: lines) else { return kind == .drag }
        if kind == .drag, let button {
            guard let drag = pressed[button]?.drag(target, in: surface) else { return true }
            if !semanticMouse(drag, surface) { pressed[button]?.observe(nil) }
        } else {
            guard semanticMouse(target, surface) else { return true }
            if kind == .down, let button {
                pressed[button] = EndpointMouseCapture(target: target, surface: surface)
                window?.makeFirstResponder(self)
            }
        }
        return true
    }
}
