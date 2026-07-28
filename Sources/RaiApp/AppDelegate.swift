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
    private var microController: MicroController?
    private var microEnabledObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        connect(to: RaiApp.sharedModel)
        installTerminalKeyMonitor()
        installTerminalScrollMonitor()
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

    // SwiftTerm's keyDown is not overridable from this module, so intercept the
    // Ghostty line-editing combos (⌘⌫ etc.) and non-ASCII text (Hebrew) here and
    // route them to whichever terminal pane is focused.
    //
    // The routing is deliberately strict: a keystroke reaches the terminal only
    // when it was aimed at the terminal's OWN key window with the terminal as
    // first responder, and no transient surface (command palette, rename sheet)
    // is open — a local monitor sees every window's events (Settings included),
    // and anything looser leaks typed text into the session behind the scenes.
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

        let request = UNNotificationRequest(
            identifier: "agent-\(pane.paneID)-\(transition.newStatus.rawValue)-\(UUID())",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
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
        let body = transition.newStatus == .blocked ? "Needs you" : "Finished"
        let workspace = snapshot.workspaceLabel(for: pane)
        postNotification(for: transition, pane: pane, in: snapshot)
        model.bridgeServer.sendPush(
            title: title,
            subtitle: workspace,
            body: body,
            paneID: pane.paneID,
            workspaceID: pane.workspaceID,
            workspace: workspace,
            requiresAttention: transition.newStatus == .blocked
        )
    }
}
