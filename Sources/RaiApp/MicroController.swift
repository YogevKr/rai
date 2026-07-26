import AppKit
import ApplicationServices
import Combine
import Foundation
import RaiCore

enum MicroControllerIntent: Equatable {
    case action(MicroAction, state: MicroPressState)
}

enum MicroControllerDecisions {
    static func assignments(from snapshot: SessionSnapshot) -> [MicroSlotAssignment] {
        snapshot.workspaces.flatMap { workspace in
            snapshot.tabs
                .filter { $0.workspaceID == workspace.workspaceID }
                .flatMap { tab in
                    snapshot.panes
                        .filter { $0.tabID == tab.tabID }
                        .map {
                            MicroSlotAssignment(
                                paneID: $0.paneID,
                                status: $0.agentStatus
                            )
                        }
                }
        }
    }

    static func statuses(from slots: [MicroSlotAssignment?]) -> [AgentStatus?] {
        slots.map { $0?.status }
    }

    static func nextPaneID(
        in slots: [MicroSlotAssignment?],
        selectedPaneID: String?,
        step: Int
    ) -> String? {
        let paneIDs = slots.compactMap { $0?.paneID }
        guard !paneIDs.isEmpty, step != 0 else { return nil }
        guard let selectedPaneID,
              let current = paneIDs.firstIndex(of: selectedPaneID) else {
            return step > 0 ? paneIDs.first : paneIDs.last
        }
        let offset = step > 0 ? 1 : -1
        return paneIDs[(current + offset + paneIDs.count) % paneIDs.count]
    }

    static func controlAndState(
        for event: MicroInputEvent
    ) -> (MicroControl, MicroPressState)? {
        switch event {
        case .agentKey(let index, let state):
            (.agentKey(index), state)
        case .commandKey(let id, let state):
            (.commandKey(id), state)
        case .encoder(.clockwise):
            (.dialClockwise, .press)
        case .encoder(.counterclockwise):
            (.dialCounterClockwise, .press)
        case .encoder(.press):
            (.dialPress, .press)
        case .encoder(.release):
            (.dialPress, .release)
        case .joystick(let direction, let state):
            (.joystick(direction), state)
        case .joystickSample, .deviceResponse, .debugLog, .unknown:
            nil
        }
    }

    static func intent(
        for event: MicroInputEvent,
        bindings: MicroBindings
    ) -> MicroControllerIntent? {
        guard let (control, state) = controlAndState(for: event) else { return nil }
        let action = bindings[control]
        // Most bindings fire on their press edge only. Wispr Flow is push-to-
        // talk: it holds its shortcut down for as long as the mic key is held,
        // so let the release edge through too.
        guard state == .press || action == .wisprFlow else { return nil }
        return .action(action, state: state)
    }
}

/// Optional Codex Micro integration. The documented default is disabled; set
/// `codexMicroEnabled` in UserDefaults to opt in.
@MainActor
final class MicroController {
    static let enabledDefaultsKey = "codexMicroEnabled"
    // Wispr Flow dictation is triggered by SIMULATING its push-to-talk chord,
    // not the wispr-flow:// URL (which foregrounds Wispr's window and drops the
    // transcript into Wispr's scratchpad instead of rai's focused pane). rai
    // holds this chord while the mic key is held; it must match exactly what
    // Wispr's push-to-talk is bound to (read from Wispr's config). Currently
    // Control+Option — a modifier-only chord, so there is no trigger key.
    static let wisprShortcutKey: CGKeyCode? = nil
    static let wisprShortcutModifiers: [(key: CGKeyCode, flag: CGEventFlags)] = [
        (0x3B, .maskControl),   // Control
        (0x3A, .maskAlternate), // Option
    ]

    private weak var model: RaiModel?
    private var worker: Worker?
    private var wisprAccessibilityLogged = false
    private var bindingsObserver: AnyCancellable?

    init(model: RaiModel) {
        self.model = model
        bindingsObserver = MicroStatusCenter.shared.bindings.$table
            .sink { [weak self] table in
                let snapshot = MicroBindings(table: table)
                self?.worker?.update(bindings: snapshot)
            }
    }

    func start() {
        guard worker == nil else { return }
        let worker = Worker(
            bindings: MicroStatusCenter.shared.bindings.copy(),
            intentHandler: { [weak self] intent, slots, ordered in
                Task { @MainActor [weak self] in
                    self?.perform(intent, slots: slots, ordered: ordered)
                }
            },
            pressedHandler: { control in
                Task { @MainActor in
                    MicroStatusCenter.shared.recordPressed(control)
                }
            }
        )
        self.worker = worker
        worker.start()
    }

    func stop() {
        worker?.stop()
        worker = nil
    }

    func update(snapshot: SessionSnapshot) {
        worker?.update(
            assignments: MicroControllerDecisions.assignments(from: snapshot),
            selectedPaneID: model?.selectedPaneID,
            onlyNeedsYou: model?.onlyNeedsYou ?? false
        )
    }

    private func perform(
        _ intent: MicroControllerIntent,
        slots: [MicroSlotAssignment?],
        ordered: [MicroSlotAssignment]
    ) {
        guard let model else { return }
        guard case .action(let action, let state) = intent else { return }
        // A pad press must not drive the session while the user is configuring
        // the pad or typing into a rai-owned transient surface. The independent
        // pressed handler still records the control for Settings learn mode.
        let suppress = MicroStatusCenter.shared.isBindingEditorActive
            || model.isCommandPalettePresented
            || model.renameRequest != nil
        if suppress { return }

        // A press on the pad pulls rai to the front so you act on the agent
        // you're driving. This INCLUDES Wispr Flow: its dictation is injected
        // into the frontmost app's focused field, so rai must be frontmost when
        // listening starts, otherwise the transcript lands in whatever app
        // happened to be focused (e.g. the Codex desktop app).
        if state == .press, action != MicroAction.none, !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        switch action {
        case .selectSlot(let index):
            guard slots.indices.contains(index), let paneID = slots[index]?.paneID else {
                return
            }
            model.select(paneID: paneID, focusInHerdr: true)
        case .focusPane(let direction):
            model.focusPane(direction)
        case .nextAgent, .prevAgent:
            // The dial walks the full agent list in sidebar order — including
            // agents that overflowed off the six keys — so nothing is
            // unreachable. The keys stay attention-first; the dial is the
            // "scroll through everything" control.
            let step = action == .nextAgent ? 1 : -1
            guard let paneID = MicroControllerDecisions.nextPaneID(
                in: ordered.map(Optional.some),
                selectedPaneID: model.selectedPaneID,
                step: step
            ) else { return }
            model.select(paneID: paneID, focusInHerdr: true)
        case .commandPalette:
            if !model.isCommandPalettePresented {
                model.toggleCommandPalette()
            }
        case .sendReturn:
            model.microSendReturnToSelectedPane()
        case .interruptEscape:
            model.microSendKeysToSelectedPane("Escape")
        case .stopCtrlC:
            model.microSendKeysToSelectedPane("C-c")
        case .approve:
            model.microSendTextToSelectedPane("y", submit: true)
        case .deny:
            model.microSendTextToSelectedPane("n", submit: true)
        case .customKeys(let keys):
            model.microSendKeysToSelectedPane(keys)
        case .customText(let text):
            model.microSendTextToSelectedPane(text, submit: true)
        case .toggleOnlyNeedsYou:
            model.onlyNeedsYou.toggle()
        case .newTab:
            model.newTab()
        case .closeTab:
            model.closeTab()
        case .reopenClosedTab:
            model.reopenClosedTab()
        case .newWorkspace:
            model.newWorkspace()
        case .collapseSpace:
            guard let workspaceID = model.selectedWorkspace?.workspaceID else { return }
            model.toggleWorkspaceCollapsed(workspaceID)
        case .splitRight:
            model.splitRight()
        case .splitDown:
            model.splitDown()
        case .closePane:
            model.closePane()
        case .broadcast:
            model.isBroadcastPresented = true
        case .wisprFlow:
            setWisprShortcut(down: state == .press)
        case .none:
            break
        }
    }

    /// Holds (or releases) Wispr Flow's push-to-talk chord so its dictation is
    /// captured into rai's focused pane. rai is already frontmost (pulled up on
    /// the key press), and posting a global chord — rather than opening the
    /// wispr-flow:// URL — keeps Wispr's own window from stealing focus. Bind
    /// Wispr's push-to-talk to the same chord (Control-Option-Semicolon).
    private func setWisprShortcut(down: Bool) {
        guard ensureAccessibilityTrusted() else { return }
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }

        func post(_ key: CGKeyCode, keyDown: Bool, flags: CGEventFlags) {
            guard let event = CGEvent(
                keyboardEventSource: source, virtualKey: key, keyDown: keyDown
            ) else { return }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }

        let modifiers = Self.wisprShortcutModifiers
        if down {
            // Press the modifiers (accumulating flags), then the trigger key (if
            // any) — and hold.
            var flags: CGEventFlags = []
            for modifier in modifiers {
                flags.insert(modifier.flag)
                post(modifier.key, keyDown: true, flags: flags)
            }
            if let key = Self.wisprShortcutKey {
                post(key, keyDown: true, flags: flags)
            }
        } else {
            // Release the trigger key (if any), then the modifiers in reverse.
            var flags: CGEventFlags = modifiers.reduce(into: []) { $0.insert($1.flag) }
            if let key = Self.wisprShortcutKey {
                post(key, keyDown: false, flags: flags)
            }
            for modifier in modifiers.reversed() {
                flags.remove(modifier.flag)
                post(modifier.key, keyDown: false, flags: flags)
            }
        }
    }

    /// True when rai may post keyboard events other apps receive. When false it
    /// shows the Accessibility prompt once and surfaces guidance in Settings —
    /// posting to `.cghidEventTap` is silently dropped without the grant.
    private func ensureAccessibilityTrusted() -> Bool {
        if AXIsProcessTrusted() { return true }
        // `kAXTrustedCheckOptionPrompt` imports inconsistently (Unmanaged vs
        // CFString) across SDKs; its value is the literal below.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if !wisprAccessibilityLogged {
            NSLog("rai: Wispr Flow needs Accessibility permission to send its shortcut")
            wisprAccessibilityLogged = true
        }
        Task { @MainActor in
            MicroStatusCenter.shared.recordError(
                "Grant rai Accessibility (System Settings → Privacy & Security) "
                    + "to send the Wispr Flow shortcut"
            )
        }
        return false
    }
}

private final class Worker: @unchecked Sendable {
    typealias IntentHandler = @Sendable (
        MicroControllerIntent,
        [MicroSlotAssignment?],
        [MicroSlotAssignment]
    ) -> Void

    private let lock = NSLock()
    private let intentHandler: IntentHandler
    private let pressedHandler: @Sendable (MicroControl) -> Void
    private var runLoop: CFRunLoop?
    private var pendingBlocks: [@Sendable () -> Void] = []
    private var stopped = false

    // Accessed only on the monitoring thread.
    private var transport: IOHIDMicroTransport?
    private var frameDecoder = MicroFrameDecoder()
    private var joystickTracker = MicroKeyMap.MicroJoystickTracker()
    private var slotAssigner = MicroSlotAssigner()
    private var lighting = MicroLighting()
    private var rpcEncoder = MicroRPCEncoder()
    private var slots: [MicroSlotAssignment?] = Array(repeating: nil, count: 6)
    // Full sidebar-order agent list (all panes, unfiltered) so the dial can step
    // through every agent, not just the six that currently hold a key.
    private var orderedPanes: [MicroSlotAssignment] = []
    private var connected = false
    private var bindings: MicroBindings

    init(
        bindings: MicroBindings,
        intentHandler: @escaping IntentHandler,
        pressedHandler: @escaping @Sendable (MicroControl) -> Void
    ) {
        self.bindings = bindings
        self.intentHandler = intentHandler
        self.pressedHandler = pressedHandler
    }

    func start() {
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "rai.codex-micro"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func stop() {
        schedule { [weak self] in
            guard let self else { return }
            transport?.close()
            transport = nil
            connected = false
            if let runLoop { CFRunLoopStop(runLoop) }
        }
        lock.withLock { stopped = true }
    }

    func update(
        assignments: [MicroSlotAssignment],
        selectedPaneID: String?,
        onlyNeedsYou: Bool
    ) {
        schedule { [weak self] in
            guard let self else { return }
            slots = slotAssigner.update(
                assignments,
                selectedPaneID: selectedPaneID,
                onlyNeedsYou: onlyNeedsYou
            )
            orderedPanes = assignments
            sendLightingChanges()
        }
    }

    func update(bindings: MicroBindings) {
        // The object is a detached value snapshot. It is installed on the HID
        // run-loop just like slot assignments, so neither UserDefaults nor the
        // observable Settings object is ever touched from this thread.
        schedule { [weak self] in self?.bindings = bindings }
    }

    private func run() {
        autoreleasepool {
            let currentRunLoop = CFRunLoopGetCurrent()
            let queued = lock.withLock { () -> [@Sendable () -> Void] in
                guard !stopped else { return [] }
                runLoop = currentRunLoop
                let queued = pendingBlocks
                pendingBlocks.removeAll()
                return queued
            }
            guard !lock.withLock({ stopped }) else { return }

            let transport = IOHIDMicroTransport()
            self.transport = transport
            transport.onReport = { [weak self] report in self?.consume(report) }
            transport.onConnectionChange = { [weak self, weak transport] connected in
                self?.connectionChanged(connected)
                let identity = transport?.currentDeviceIdentity
                Task { @MainActor in
                    if connected {
                        MicroStatusCenter.shared.deviceAttached(identity: identity)
                    } else {
                        MicroStatusCenter.shared.deviceDetached()
                    }
                }
            }
            do {
                try transport.openMonitoring()
            } catch {
                let message = error.localizedDescription
                NSLog("rai: Codex Micro monitoring failed: \(message)")
                Task { @MainActor in MicroStatusCenter.shared.recordError(message) }
                return
            }
            queued.forEach { $0() }
            CFRunLoopRun()
            transport.close()
        }
    }

    private func schedule(_ block: @escaping @Sendable () -> Void) {
        let target = lock.withLock { () -> CFRunLoop? in
            guard !stopped else { return nil }
            guard let runLoop else {
                pendingBlocks.append(block)
                return nil
            }
            return runLoop
        }
        guard let target else { return }
        CFRunLoopPerformBlock(target, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(target)
    }

    private func connectionChanged(_ isConnected: Bool) {
        connected = isConnected
        guard isConnected else { return }
        lighting = MicroLighting()
        sendLightingChanges()
    }

    private func sendLightingChanges() {
        guard connected else { return }
        let changes = lighting.changes(
            for: MicroControllerDecisions.statuses(from: slots)
        )
        guard !changes.isEmpty, let transport else { return }
        do {
            let request = try rpcEncoder.request(
                method: "v.oai.thstatus",
                params: changes
            )
            for report in try MicroFraming.encode(request.payload) {
                try transport.send(report: report)
            }
        } catch {
            let message = error.localizedDescription
            NSLog("rai: Codex Micro lighting update failed: \(message)")
            Task { @MainActor in MicroStatusCenter.shared.recordError(message) }
        }
    }

    private func consume(_ report: [UInt8]) {
        for output in frameDecoder.consume(report) {
            handle(MicroRPCDecoder.decode(output))
        }
    }

    private func handle(_ event: MicroInputEvent) {
        if case .joystickSample(let angle, let distance) = event {
            for edge in joystickTracker.update(angle: angle, distance: distance) {
                handle(.joystick(direction: edge.direction, state: edge.state))
            }
            return
        }
        // Device replies are not input, but they are the only positive proof the
        // link is alive, so surface them for Settings rather than dropping them.
        if case .deviceResponse(_, _, let error) = event {
            Task { @MainActor in
                if let error {
                    MicroStatusCenter.shared.recordError(
                        "device error \(error.code): \(error.message)"
                    )
                } else {
                    MicroStatusCenter.shared.recordAcknowledgedWrite()
                }
            }
            return
        }
        if let (control, state) = MicroControllerDecisions.controlAndState(for: event),
           state == .press {
            pressedHandler(control)
        }
        guard let intent = MicroControllerDecisions.intent(
            for: event,
            bindings: bindings
        ) else { return }
        intentHandler(intent, slots, orderedPanes)
    }
}
