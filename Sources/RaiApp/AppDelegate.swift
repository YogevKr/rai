import AppKit
import Combine
import RaiCore
@preconcurrency import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private enum NotificationKey {
        static let paneID = "pane_id"
        static let workspaceID = "workspace_id"
        static let workspace = "workspace"
    }

    private enum Category {
        static let attention = "AGENT_ATTENTION"
        static let completion = "AGENT_COMPLETION"
        static let openAgent = "OPEN_AGENT"
    }

    @MainActor
    private func setMicroIntegration(enabled: Bool) {
        if enabled {
            guard microController == nil else { return }
            let controller = MicroController(model: RaiApp.sharedModel)
            microController = controller
            controller.start()
            if let snapshot = RaiApp.sharedModel.snapshot {
                controller.update(snapshot: snapshot)
            }
        } else {
            microController?.stop()
            microController = nil
        }
    }

    private weak var model: RaiModel?
    private var pendingPaneID: String?
    /// Panes we posted a "Needs you" notification for — retracted when the
    /// pane stops being blocked (handled at the desk).
    private var notifiedBlockedPanes: Set<String> = []
    /// Phone pushes held while the user is active at the Mac, keyed by pane.
    private var heldPushes: [String: Task<Void, Never>] = [:]
    private var activeNotificationStatuses: [String: AgentStatus] = [:]
    private var pendingNotificationBodies: [String: String] = [:]
    private var deliveredNotificationBodies: [String: String] = [:]
    private var notificationConnectionID: UUID?
    private var microController: MicroController?
    private var microEnabledObserver: AnyCancellable?
    private var hookBeaconReceiver: HookBeaconReceiver?

    func applicationDidFinishLaunching(_ notification: Notification) {
        connect(to: RaiApp.sharedModel)
        startHookBeaconReceiver(model: RaiApp.sharedModel)
        installCloseRepeatGuard()
        installTerminalKeyMonitor()
        installTerminalScrollMonitor()
        disableWindowSnapshots()
        microEnabledObserver = MicroStatusCenter.shared.$isEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                Task { @MainActor in self?.setMicroIntegration(enabled: enabled) }
            }

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Category.attention,
                actions: [
                    UNNotificationAction(
                        identifier: Category.openAgent,
                        title: "Show Agent",
                        options: .foreground
                    ),
                ],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: Category.completion,
                actions: [
                    UNNotificationAction(
                        identifier: Category.openAgent,
                        title: "Show Agent",
                        options: .foreground
                    ),
                ],
                intentIdentifiers: []
            ),
        ])
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await model?.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        hookBeaconReceiver?.stop()
        microController?.stop()
    }

    private func startHookBeaconReceiver(model: RaiModel) {
        let receiver = HookBeaconReceiver { [weak model] beacon in
            Task { @MainActor in
                await model?.receiveAgentBeacon(beacon)
            }
        }
        do {
            try receiver.start()
            hookBeaconReceiver = receiver
        } catch {
            NSLog("rai: Claude hook receiver failed: %@", error.localizedDescription)
        }
    }

    // macOS's window-restoration snapshotter re-captures the entire window
    // bitmap whenever streaming output dirties it — a full core of memmove on
    // a large display. Rai rebuilds its UI from herd state at launch, so the
    // OS snapshot buys nothing; window frame restoration is unaffected.
    private func disableWindowSnapshots() {
        for window in NSApp.windows {
            window.disableSnapshotRestoration()
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { notification in
            MainActor.assumeIsolated {
                (notification.object as? NSWindow)?.disableSnapshotRestoration()
            }
        }
    }

    // SwiftTerm's keyDown is not overridable from this module, so intercept the
    // Ghostty line-editing combos (⌘⌫ etc.) and non-ASCII text (Hebrew) here and
    // route them to whichever terminal pane is focused.
    //
    // The routing is deliberately strict: a keystroke reaches the terminal only
    // when it was aimed at the terminal's OWN key window with the terminal as
    // first responder, and no transient surface (command palette, rename sheet)
    // is open — a local monitor sees every window's events (Settings included),
    // and anything looser leaks typed text into the session behind the scenes.
    /// Drops auto-repeats of ⌘W / ⌘⇧W before AppKit can fire their menu items.
    /// Installed ahead of the terminal monitor so a held ⌘W dies here rather
    /// than racing the routing rules below.
    private func installCloseRepeatGuard() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event -> NSEvent? in
            KeyRoutingDecision.isRepeatedCloseShortcut(
                isARepeat: event.isARepeat,
                command: event.modifierFlags.contains(.command),
                option: event.modifierFlags.contains(.option),
                control: event.modifierFlags.contains(.control),
                shift: event.modifierFlags.contains(.shift),
                charactersIgnoringModifiers: event.charactersIgnoringModifiers
            ) ? nil : event
        }
    }

    private func installTerminalKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event -> NSEvent? in
            MainActor.assumeIsolated {
                guard let window = event.window,
                      let term = window.firstResponder as? FocusAwareTerminalView,
                      KeyRoutingDecision.shouldRouteToTerminal(
                          eventWindowIsKey: window.isKeyWindow,
                          terminalIsInEventWindow: term.window === window,
                          palettePresented: self?.model?.isCommandPalettePresented ?? false,
                          renamePresented: self?.model?.renameRequest != nil
                      ),
                      term.handleInterceptedKey(event) else {
                    return event
                }
                return nil
            }
        }
    }

    // Terminal panes keep `allowMouseReporting` off so SwiftTerm preserves the
    // text selection while a program streams output (its feed path clears the
    // selection whenever reporting is on). The wheel must still reach mouse-mode
    // TUIs (Claude scrolls its own viewport), and SwiftTerm's `scrollWheel` is
    // not overridable from this module — so route wheel events over a terminal
    // through it with reporting enabled just for that synchronous dispatch.
    private func installTerminalScrollMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event -> NSEvent? in
            MainActor.assumeIsolated {
                guard let content = event.window?.contentView else { return event }
                let point = content.superview?.convert(event.locationInWindow, from: nil)
                    ?? event.locationInWindow
                var view = content.hitTest(point)
                while let current = view {
                    if let term = current as? FocusAwareTerminalView {
                        term.handleInterceptedScroll(event)
                        return nil
                    }
                    view = current.superview
                }
                return event
            }
        }
    }

    private func connect(to model: RaiModel) {
        self.model = model
        model.snapshotObserver = self
        updateDockBadge(count: model.blockedAgentCount)
        if let snapshot = model.snapshot {
            focusPendingPane(in: snapshot, model: model)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let paneID = response.notification.request.content
            .userInfo[NotificationKey.paneID] as? String

        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            let window = NSApp.mainWindow
                ?? NSApp.keyWindow
                ?? NSApp.windows.first(where: { $0.canBecomeMain })
            window?.deminiaturize(nil)
            window?.makeKeyAndOrderFront(nil)

            if let paneID {
                if model?.snapshot == nil {
                    pendingPaneID = paneID
                } else {
                    model?.select(paneID: paneID, focusInHerdr: true)
                }
            }
        }
    }

    private func updateDockBadge(count: Int) {
        NSApp.dockTile.badgeLabel = count == 0 ? nil : String(count)
    }

    private func focusPendingPane(
        in snapshot: SessionSnapshot,
        model: RaiModel
    ) {
        guard let pendingPaneID else { return }
        self.pendingPaneID = nil
        if snapshot.panes.contains(where: { $0.paneID == pendingPaneID }) {
            model.select(paneID: pendingPaneID, focusInHerdr: true)
        }
    }

    private func postNotification(
        for transition: PaneStatusTransition,
        pane: Pane,
        in snapshot: SessionSnapshot,
        body: String,
        isUpdate: Bool = false
    ) {
        let content = UNMutableNotificationContent()
        content.title = snapshot.displayName(for: pane)
        content.body = body
        content.subtitle = snapshot.workspaceLabel(for: pane)
        let soundChoice = transition.newStatus == .blocked
            ? SettingsStore.shared.blockedNotificationSound
            : SettingsStore.shared.doneNotificationSound
        content.sound = isUpdate ? nil : Self.notificationSound(for: soundChoice)
        content.categoryIdentifier = transition.newStatus == .blocked
            ? Category.attention
            : Category.completion
        content.userInfo = [
            NotificationKey.paneID: pane.paneID,
            NotificationKey.workspaceID: pane.workspaceID,
            NotificationKey.workspace: snapshot.workspaceLabel(for: pane),
        ]

        // Stable per-pane identifier: a newer notification for the same pane
        // REPLACES the older one in Notification Center instead of stacking
        // ("Needs you" superseded by "Finished" reads as one story, not two).
        let request = UNNotificationRequest(
            identifier: Self.notificationIdentifier(paneID: pane.paneID),
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    static func notificationIdentifier(paneID: String) -> String {
        "agent-\(paneID)"
    }

    private static func notificationSound(
        for choice: NotificationSoundChoice
    ) -> UNNotificationSound? {
        switch choice {
        case .default:
            .default
        case .none:
            nil
        case let .named(name):
            UNNotificationSound(named: UNNotificationSoundName(rawValue: "\(name).aiff"))
        }
    }
}

extension AppDelegate: RaiSnapshotObserver {
    func raiModel(
        _ model: RaiModel,
        didRefresh snapshot: SessionSnapshot,
        transitions: [PaneStatusTransition]
    ) {
        if notificationConnectionID != model.connectionIDForObservers {
            clearAllNotificationState()
            notificationConnectionID = model.connectionIDForObservers
        }
        updateDockBadge(
            count: snapshot.panes.lazy.filter { $0.agentStatus == .blocked }.count
        )

        let statuses = Dictionary(
            uniqueKeysWithValues: snapshot.panes.map { ($0.paneID, $0.agentStatus) }
        )
        let staleNotificationPanes = activeNotificationStatuses.compactMap {
            paneID, status in
            statuses[paneID] != status || paneID == model.selectedPaneID
                ? paneID
                : nil
        }
        for paneID in staleNotificationPanes {
            clearNotificationState(forPane: paneID)
        }

        // Retract notifications the user has implicitly handled: the pane
        // they're looking at, and any pane that is no longer blocked (answered
        // at the desk means the phoneside banner shouldn't linger either).
        var retractIDs: [String] = []
        if let selected = model.selectedPaneID {
            retractIDs.append(Self.notificationIdentifier(paneID: selected))
        }
        let blockedNow = Set(
            snapshot.panes.lazy.filter { $0.agentStatus == .blocked }.map(\.paneID)
        )
        for paneID in notifiedBlockedPanes.subtracting(blockedNow) {
            retractIDs.append(Self.notificationIdentifier(paneID: paneID))
            notifiedBlockedPanes.remove(paneID)
        }
        if !retractIDs.isEmpty {
            UNUserNotificationCenter.current()
                .removeDeliveredNotifications(withIdentifiers: retractIDs)
        }

        focusPendingPane(in: snapshot, model: model)
        microController?.update(snapshot: snapshot)

        guard !model.notificationsMuted else { return }
        for transition in transitions where transition.paneID != model.selectedPaneID {
            guard let pane = snapshot.panes.first(where: {
                $0.paneID == transition.paneID
            }) else { continue }
            activeNotificationStatuses[pane.paneID] = transition.newStatus
            let beacon = model.beacon(forPane: pane.paneID)
            let body = AgentNotificationBody.compose(
                status: transition.newStatus,
                beacon: beacon
            )
            let allowsRemoteActions = transition.newStatus == .blocked
                && beacon == nil
                && !ClaudeHooksInstaller.hasManagedHooks()
            if transition.newStatus == .done {
                // herdr derives "done" from working→idle, so a session that
                // paused to wait on a background shell/monitor reports done
                // while it isn't finished. Check for pending background work
                // and swallow the false "Finished"; the real one fires after
                // the background work completes and the session wraps up.
                Task { [weak self, weak model] in
                    guard let self, let model else { return }
                    let pending = await model.pendingBackgroundWork(forPane: pane.paneID)
                    guard pending.isEmpty else {
                        self.clearNotificationState(forPane: pane.paneID)
                        return
                    }
                    let currentBody = self.pendingNotificationBodies[pane.paneID] ?? body
                    self.deliver(
                        transition: transition,
                        pane: pane,
                        in: snapshot,
                        model: model,
                        body: currentBody,
                        allowsRemoteActions: false
                    )
                }
            } else {
                deliver(
                    transition: transition,
                    pane: pane,
                    in: snapshot,
                    model: model,
                    body: body,
                    allowsRemoteActions: allowsRemoteActions
                )
            }
        }
    }

    private func deliver(
        transition: PaneStatusTransition,
        pane: Pane,
        in snapshot: SessionSnapshot,
        model: RaiModel,
        body: String,
        allowsRemoteActions: Bool,
        isUpdate: Bool = false
    ) {
        let title = snapshot.displayName(for: pane)
        let workspace = snapshot.workspaceLabel(for: pane)
        if transition.newStatus == .blocked {
            notifiedBlockedPanes.insert(pane.paneID)
        }
        deliveredNotificationBodies[pane.paneID] = body
        pendingNotificationBodies.removeValue(forKey: pane.paneID)
        postNotification(
            for: transition,
            pane: pane,
            in: snapshot,
            body: body,
            isUpdate: isUpdate
        )

        heldPushes.removeValue(forKey: pane.paneID)?.cancel()
        let sendPush = { [weak model] in
            model?.bridgeServer.sendPush(
                title: title,
                subtitle: workspace,
                body: body,
                paneID: pane.paneID,
                workspaceID: pane.workspaceID,
                workspace: workspace,
                requiresAttention: allowsRemoteActions
            )
        }
        guard SettingsStore.shared.holdPushesWhileAtMac,
              UserPresence.idleSeconds < UserPresence.awayAfter else {
            sendPush()
            return
        }
        // User is at the Mac: hold the push. It fires only if the pane still
        // wants the same attention after they go idle; handled at the desk
        // (status changed, pane selected, pane gone) means it dies quietly.
        let paneID = pane.paneID
        let expected = transition.newStatus
        heldPushes[paneID] = Task { [weak self, weak model] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(UserPresence.pollInterval))
                guard let self, let model, !Task.isCancelled else { return }
                let decision = HeldPushDecision.evaluate(
                    paneStatus: model.snapshot?.panes
                        .first { $0.paneID == paneID }?.agentStatus,
                    expectedStatus: expected,
                    isSelectedOnMac: model.selectedPaneID == paneID,
                    idleSeconds: UserPresence.idleSeconds,
                    awayAfter: UserPresence.awayAfter
                )
                switch decision {
                case .wait:
                    continue
                case .push:
                    sendPush()
                    fallthrough
                case .cancel:
                    self.heldPushes.removeValue(forKey: paneID)
                    return
                }
            }
        }
    }

    func raiModel(
        _ model: RaiModel,
        didReceive beacon: AgentBeacon,
        forPane paneID: String
    ) {
        guard !model.notificationsMuted,
              paneID != model.selectedPaneID,
              let snapshot = model.snapshot,
              let pane = snapshot.panes.first(where: { $0.paneID == paneID }),
              activeNotificationStatuses[paneID] == pane.agentStatus,
              pane.agentStatus != .done || beacon.completionSummary != nil else { return }
        let body = AgentNotificationBody.compose(
            status: pane.agentStatus,
            beacon: beacon
        )
        guard body != deliveredNotificationBodies[paneID] else { return }

        pendingNotificationBodies[paneID] = body
        guard deliveredNotificationBodies[paneID] != nil else { return }
        deliver(
            transition: PaneStatusTransition(
                paneID: paneID,
                newStatus: pane.agentStatus
            ),
            pane: pane,
            in: snapshot,
            model: model,
            body: body,
            allowsRemoteActions: false,
            isUpdate: true
        )
    }

    private func clearNotificationState(forPane paneID: String) {
        activeNotificationStatuses.removeValue(forKey: paneID)
        pendingNotificationBodies.removeValue(forKey: paneID)
        deliveredNotificationBodies.removeValue(forKey: paneID)
    }

    private func clearAllNotificationState() {
        let paneIDs = Set(activeNotificationStatuses.keys).union(notifiedBlockedPanes)
        let identifiers = paneIDs.map { Self.notificationIdentifier(paneID: $0) }
        if !identifiers.isEmpty {
            UNUserNotificationCenter.current()
                .removeDeliveredNotifications(withIdentifiers: identifiers)
        }
        heldPushes.values.forEach { $0.cancel() }
        heldPushes.removeAll()
        activeNotificationStatuses.removeAll()
        pendingNotificationBodies.removeAll()
        deliveredNotificationBodies.removeAll()
        notifiedBlockedPanes.removeAll()
    }
}
