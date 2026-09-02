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
    /// The status represented by each stable local notification identifier.
    private var notifiedPaneStatuses = NotifiedPaneStore.load()
    /// Phone events waiting for the presence and burst gates, keyed by pane.
    private var pendingPhonePushes: [String: PhonePushEvent] = [:]
    /// One worker owns both presence polling and burst timing.
    private var phonePushGateTask: Task<Void, Never>?
    private var microController: MicroController?
    private var microEnabledObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        connect(to: RaiApp.sharedModel)
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
        microController?.stop()
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
        in snapshot: SessionSnapshot
    ) {
        let content = UNMutableNotificationContent()
        content.title = snapshot.displayName(for: pane)
        content.body = transition.newStatus == .blocked ? "Needs you" : "Finished"
        content.subtitle = snapshot.workspaceLabel(for: pane)
        let soundChoice = transition.newStatus == .blocked
            ? SettingsStore.shared.blockedNotificationSound
            : SettingsStore.shared.doneNotificationSound
        content.sound = Self.notificationSound(for: soundChoice)
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
        PushNotificationIdentity.pane(paneID)
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
        updateDockBadge(
            count: snapshot.panes.lazy.filter { $0.agentStatus == .blocked }.count
        )

        // Retract notifications the user handled, panes that closed, and any
        // notification whose represented status is no longer current.
        var retractIDs: [String] = []
        let panesByID = Dictionary(uniqueKeysWithValues: snapshot.panes.map { ($0.paneID, $0) })
        let notifiedPaneIDsToRemove = NotificationRetractionPlanner.paneIDs(
            notifiedStatuses: notifiedPaneStatuses,
            currentStatuses: panesByID.mapValues(\.agentStatus),
            selectedPaneID: model.selectedPaneID
        )
        for paneID in notifiedPaneIDsToRemove {
            retractIDs.append(Self.notificationIdentifier(paneID: paneID))
            notifiedPaneStatuses.removeValue(forKey: paneID)
        }
        if !notifiedPaneIDsToRemove.isEmpty {
            NotifiedPaneStore.save(notifiedPaneStatuses)
        }
        var pendingPaneIDsToRemove: [String] = []
        for (paneID, event) in pendingPhonePushes {
            let isSelected = paneID == model.selectedPaneID
            if isSelected || panesByID[paneID]?.agentStatus != event.status {
                pendingPaneIDsToRemove.append(paneID)
            }
        }
        for paneID in pendingPaneIDsToRemove {
            pendingPhonePushes.removeValue(forKey: paneID)
        }
        updatePresenceStatus()
        retractIDs = Array(Set(retractIDs)).sorted()
        if !retractIDs.isEmpty {
            UNUserNotificationCenter.current()
                .removeDeliveredNotifications(withIdentifiers: retractIDs)
            model.bridgeServer.retractPushNotifications(identifiers: retractIDs)
        }

        focusPendingPane(in: snapshot, model: model)
        microController?.update(snapshot: snapshot)

        guard !model.notificationsMuted else { return }
        for transition in transitions where transition.paneID != model.selectedPaneID {
            guard let pane = snapshot.panes.first(where: {
                $0.paneID == transition.paneID
            }) else { continue }
            if transition.newStatus == .done {
                // herdr derives "done" from working→idle, so a session that
                // paused to wait on a background shell/monitor reports done
                // while it isn't finished. Check for pending background work
                // and swallow the false "Finished"; the real one fires after
                // the background work completes and the session wraps up.
                Task { [weak self, weak model] in
                    guard let self, let model else { return }
                    let pending = await model.pendingBackgroundWork(forPane: pane.paneID)
                    guard pending.isEmpty else { return }
                    guard model.selectedPaneID != pane.paneID,
                          model.snapshot?.panes.first(where: {
                              $0.paneID == pane.paneID
                          })?.agentStatus == transition.newStatus else { return }
                    self.deliver(transition: transition, pane: pane, in: snapshot, model: model)
                }
            } else {
                deliver(transition: transition, pane: pane, in: snapshot, model: model)
            }
        }
    }

    private func deliver(
        transition: PaneStatusTransition,
        pane: Pane,
        in snapshot: SessionSnapshot,
        model: RaiModel
    ) {
        let title = snapshot.displayName(for: pane)
        let workspace = snapshot.workspaceLabel(for: pane)
        notifiedPaneStatuses[pane.paneID] = transition.newStatus
        NotifiedPaneStore.save(notifiedPaneStatuses)
        postNotification(for: transition, pane: pane, in: snapshot)
        pendingPhonePushes[pane.paneID] = PhonePushEvent(
            paneID: pane.paneID,
            paneName: title,
            workspaceID: pane.workspaceID,
            workspaceName: workspace,
            status: transition.newStatus,
            occurredAt: Date()
        )
        updatePresenceStatus()
        startPhonePushGate(model: model)
    }

    private func startPhonePushGate(model: RaiModel) {
        guard phonePushGateTask == nil else { return }
        phonePushGateTask = Task { [weak self, weak model] in
            while !Task.isCancelled {
                guard let self, let model else { return }
                self.removeStalePendingPushes(model: model)
                guard !self.pendingPhonePushes.isEmpty else {
                    self.phonePushGateTask = nil
                    self.updatePresenceStatus()
                    return
                }

                let idleSeconds = UserPresence.idleSeconds
                let gateIsHolding = SettingsStore.shared.holdPushesWhileAtMac
                    && idleSeconds < UserPresence.awayAfter
                self.updatePresenceStatus(idleSeconds: idleSeconds)
                if gateIsHolding {
                    try? await Task.sleep(for: .seconds(UserPresence.pollInterval))
                    continue
                }

                let newest = self.pendingPhonePushes.values
                    .map(\.occurredAt).max() ?? Date()
                let remaining = UserPresence.burstWindow
                    - Date().timeIntervalSince(newest)
                if remaining > 0 {
                    try? await Task.sleep(for: .seconds(remaining))
                    continue
                }

                let events = Array(self.pendingPhonePushes.values)
                self.pendingPhonePushes.removeAll()
                self.updatePresenceStatus(idleSeconds: idleSeconds)
                for burst in PushBurstPlanner.plan(
                    events: events,
                    window: UserPresence.burstWindow
                ) {
                    model.bridgeServer.sendPush(burst)
                }
            }
        }
    }

    private func removeStalePendingPushes(model: RaiModel) {
        let panes = Dictionary(
            uniqueKeysWithValues: (model.snapshot?.panes ?? []).map { ($0.paneID, $0) }
        )
        let stalePaneIDs = pendingPhonePushes.compactMap { paneID, event in
            let decision = HeldPushDecision.evaluate(
                paneStatus: panes[paneID]?.agentStatus,
                expectedStatus: event.status,
                isSelectedOnMac: model.selectedPaneID == paneID,
                idleSeconds: UserPresence.idleSeconds,
                awayAfter: UserPresence.awayAfter
            )
            return decision == .cancel ? paneID : nil
        }
        for paneID in stalePaneIDs {
            pendingPhonePushes.removeValue(forKey: paneID)
        }
    }

    private func updatePresenceStatus(idleSeconds: TimeInterval = UserPresence.idleSeconds) {
        PushPresenceStatus.shared.update(
            pendingCount: pendingPhonePushes.count,
            isAway: idleSeconds >= UserPresence.awayAfter
        )
    }
}
