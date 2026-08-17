import AppKit
import ApplicationServices
import Combine
import Foundation
import RaiCore

enum MicroControllerIntent: Equatable {
    case action(MicroAction, state: MicroPressState)
}

enum MicroControllerDecisions {
    /// Whether a pad press may drive the terminal session. A press must never
    /// reach the session while the user is interacting with a different
    /// context: the binding editor, the command palette, a rename sheet, or
    /// any key window that doesn't host the session terminal (e.g. Settings).
    /// `keyWindowHostsTerminal` is nil when the app has no key window (rai in
    /// the background) — pad presses are the point of a macropad, so allow.
    static func shouldSuppressPadAction(
        bindingEditorActive: Bool,
        palettePresented: Bool,
        renamePresented: Bool,
        keyWindowHostsTerminal: Bool?
    ) -> Bool {
        bindingEditorActive
            || palettePresented
            || renamePresented
            || keyWindowHostsTerminal == false
    }

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
        let keyWindow = NSApp.keyWindow
        let suppress = MicroControllerDecisions.shouldSuppressPadAction(
            bindingEditorActive: MicroStatusCenter.shared.isBindingEditorActive,
            palettePresented: model.isCommandPalettePresented,
            renamePresented: model.renameRequest != nil,
            keyWindowHostsTerminal: keyWindow.map { Self.hostsTerminal($0.contentView) }
        )
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

    /// `stop()` sets this SYNCHRONOUSLY, unlike deallocation: `run()`'s own
    /// call frame keeps `self` alive on the monitoring thread until the
    /// scheduled teardown block actually executes there, so a `[weak self]`
    /// liveness check cannot detect "stop() was called" — only this can.
    var isStopped: Bool { lock.withLock { stopped } }

    /// Wraps a transport-callback body with the isStopped gate above — the
    /// single choke point for it, instead of `guard let self, !self.isStopped
    /// else { return }` copy-pasted at every callback assignment, where a
    /// future callback (added to `MicroLink`, or a rewiring here) could
    /// easily omit it and silently reintroduce the stray-event-after-stop
    /// race the comments at each call site describe.
    private func guarded<T>(_ body: @escaping (Worker, T) -> Void) -> (T) -> Void {
        { [weak self] value in
            guard let self, !self.isStopped else { return }
            body(self, value)
        }
    }

    // Accessed only on the monitoring thread.
    private var transport: (any MicroLink)?
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

            // Prefer the rai-microd helper when it answers a probe connect:
            // macOS 26.6 blocks raw HID on keyboard-class devices for
            // non-root processes (input withheld, writes refused with
            // kIOReturnNotPermitted), and only the root helper restores the
            // link there. A socket file whose daemon does not answer (stale
            // file, another user's install) must NOT capture the link — fall
            // back to direct HID, which still works on older macOS, and say
            // why. Selection reruns on every integration toggle.
            // Policy (and its rationale) lives in RaiCore next to the probe;
            // this site only builds the chosen transport.
            let transport: any MicroLink
            switch MicroHelperTransport.chooseLink(
                probe: MicroHelperTransport.probeHelper(),
                directHIDRestricted: MicroHelperTransport.directHIDRestricted
            ) {
            case .helper:
                transport = MicroHelperTransport()
                NSLog("rai: Codex Micro link via rai-microd helper")
            case .direct:
                transport = IOHIDMicroTransport()
                NSLog("rai: Codex Micro link direct")
            case .directWithError(let reason):
                transport = IOHIDMicroTransport()
                let message = "rai-microd's socket exists but is not usable "
                    + "(\(reason)); using the direct HID link. "
                    + MicroHelperWire.reinstallOrRemoveHint
                NSLog("rai: Codex Micro: %@", message)
                // probeHelper() above can block up to 1 second (its
                // handshake timeout) — the SAME "user disabled the
                // integration while this Worker was mid-setup" race the
                // onLinkError/onReport/onConnectionChange callbacks below
                // are guarded against, just on the synchronous setup path
                // instead of a callback.
                if !lock.withLock({ stopped }) {
                    Task { @MainActor in MicroStatusCenter.shared.recordError(message) }
                }
            }
            self.transport = transport
            transport.onDiagnostic = { message in
                NSLog("rai: Codex Micro: %@", message)
            }
            // The helper link retries instead of throwing, so its failures
            // must reach Settings through this callback; the direct link
            // throws from openMonitoring and never fires it.
            //
            // All three callbacks below go through `guarded`: `self` alone
            // can be non-nil for a Worker that has already had stop()
            // called, since run()'s own call frame keeps it alive until the
            // scheduled teardown block actually executes on the monitoring
            // thread. onReport in particular can otherwise still drive a
            // real pane select/keystroke from a stray HID report after the
            // user disabled the integration; onConnectionChange can still
            // issue a real hardware write via connectionChanged() (which
            // resets lighting state and repaints it).
            transport.onLinkError = guarded { _, message in
                Task { @MainActor in MicroStatusCenter.shared.recordError(message) }
            }
            transport.onReport = guarded { worker, report in
                worker.consume(report)
            }
            transport.onConnectionChange = guarded { [weak transport] worker, connected in
                worker.connectionChanged(connected)
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
                // Same race as above: stop() could have landed while this
                // call was in flight.
                if !lock.withLock({ stopped }) {
                    Task { @MainActor in MicroStatusCenter.shared.recordError(message) }
                }
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
        } catch MicroTransportError.notOpen {
            // The link went down between our `connected` check and the send —
            // a routine unplug/helper-restart race, not an error. The detach
            // callback is already in flight, and lighting repaints from a
            // fresh baseline on the next attach.
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


extension MicroController {
    /// Whether a view hierarchy contains a session terminal. Used to tell the
    /// main window (hosts panes) apart from auxiliary key windows (Settings).
    static func hostsTerminal(_ view: NSView?) -> Bool {
        guard let view else { return false }
        if view is FocusAwareTerminalView { return true }
        return view.subviews.contains { hostsTerminal($0) }
    }
}
