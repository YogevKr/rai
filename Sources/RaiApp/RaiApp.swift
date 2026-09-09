import AppKit
import RaiCore
import SwiftUI

private struct PrimaryRaiWindowFocusKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var primaryRaiWindow: Bool? {
        get { self[PrimaryRaiWindowFocusKey.self] }
        set { self[PrimaryRaiWindowFocusKey.self] = newValue }
    }
}

@main
struct RaiApp: App {
    init() {
        do {
            try LabLaunch.validate(
                bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
                environment: ProcessInfo.processInfo.environment
            )
        } catch {
            fputs("Rai lab: \(error.localizedDescription)\n", stderr)
            exit(2)
        }
        if ProcessInfo.processInfo.arguments.contains("--validate-lab") { exit(0) }
    }

    @MainActor static let sharedModel = RaiModel()

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = RaiApp.sharedModel
    @StateObject private var settings = SettingsStore.shared
    @StateObject private var appUpdates = AppUpdateController.shared
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.endpointWindow) private var endpointWindow
    @FocusedValue(\.primaryRaiWindow) private var primaryWindow

    var body: some Scene {
        WindowGroup {
            RaiRootView(model: model)
                .focusedSceneValue(\.primaryRaiWindow, true)
                .frame(minWidth: 920, minHeight: 600)
                .preferredColorScheme(settings.appearanceMode.preferredColorScheme)
                .task {
                    model.bridgeServer.apnsSettings.migrateLegacyKeyIfNeeded()
                    model.start()
                }
        }
        .defaultSize(width: 1240, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Window") { openWindow(id: "independent") }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(model.serverInfo?.capabilities?.endpointProtocolGeneration != 1)
            }

            // SwiftUI's default Close command lives in saveItem and otherwise
            // takes Command-W before the Tab menu can handle it.
            CommandGroup(replacing: .saveItem) {
                Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w", modifiers:
                        primaryWindow == true || endpointWindow != nil ? [.command, .option] : .command)
            }

            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await AppUpdateController.shared.check(manual: true) }
                }
            }

            CommandMenu("Tab") {
              if let endpointWindow {
                EndpointTabMenu(model: endpointWindow)
                    .disabled(appUpdates.isPresented)
              } else {
              Group {
                Button("New Tab") { model.newTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Reopen Closed Tab") { model.reopenClosedTab() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(!model.canReopenClosedTab)
                Button("Close Tab") {
                    guard primaryWindow == true, !appUpdates.isPresented else { return }
                    model.closeTab()
                }
                    .keyboardShortcut(primaryWindow == true ? KeyboardShortcut("w", modifiers: .command) : nil)
                    .disabled(primaryWindow != true || appUpdates.isPresented)
                Divider()
                Button("Next Tab") { model.nextTab() }
                    .keyboardShortcut(.tab, modifiers: .control)
                Button("Previous Tab") { model.prevTab() }
                    .keyboardShortcut(.tab, modifiers: [.control, .shift])
                Divider()
                ForEach(1...9, id: \.self) { n in
                    Button("Select Tab \(n)") { model.selectTab(index: n - 1) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                }
              }
              }
            }

            CommandMenu("Pane") {
              if let endpointWindow {
                EndpointPaneMenu(model: endpointWindow)
                    .disabled(appUpdates.isPresented)
              } else {
              Group {
                Button("Split Right") { model.splitRight() }
                    .keyboardShortcut("d", modifiers: .command)
                Button("Split Down") { model.splitDown() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Close Pane") {
                    guard primaryWindow == true, !appUpdates.isPresented else { return }
                    model.closePane()
                }
                    .keyboardShortcut(primaryWindow == true ? KeyboardShortcut("w", modifiers: [.command, .shift]) : nil)
                    .disabled(primaryWindow != true || appUpdates.isPresented)
                Button("Zoom Pane") { model.zoomPane() }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                Divider()
                Menu("Split and Launch Agent") {
                    Button("Claude — Right") {
                        model.launchAgent(.claude, direction: .right)
                    }
                    Button("Claude — Down") {
                        model.launchAgent(.claude, direction: .down)
                    }
                    Divider()
                    Button("Codex — Right") {
                        model.launchAgent(.codex, direction: .right)
                    }
                    Button("Codex — Down") {
                        model.launchAgent(.codex, direction: .down)
                    }
                    Divider()
                    Button("Muse — Right") { model.launchAgent(.muse, direction: .right) }
                        .disabled((model.serverInfo?.protocol ?? 0) < 22)
                    Button("Muse — Down") { model.launchAgent(.muse, direction: .down) }
                        .disabled((model.serverInfo?.protocol ?? 0) < 22)
                }
                Divider()
                Button("Focus Left") { model.focusPane("left") }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button("Focus Right") { model.focusPane("right") }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button("Focus Up") { model.focusPane("up") }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("Focus Down") { model.focusPane("down") }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
              }
              }
            }

            CommandMenu("Agent") {
                ForEach(1...9, id: \.self) { n in
                    Button("Focus Agent \(n)") {
                        let entries = model.agentPanelEntries
                        guard entries.indices.contains(n - 1) else { return }
                        model.select(
                            paneID: entries[n - 1].paneID,
                            focusInHerdr: true
                        )
                    }
                    .keyboardShortcut(
                        KeyEquivalent(Character("\(n)")),
                        modifiers: [.command, .option]
                    )
                    .disabled(model.agentPanelEntries.count < n)
                }
                .disabled(endpointWindow != nil)
            }

            CommandMenu("Space") {
              if let endpointWindow {
                EndpointSpaceMenu(model: endpointWindow)
              } else {
              Group {
                Button("New Space") { model.newWorkspace() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Next Space") { model.nextWorkspace() }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Space") { model.prevWorkspace() }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
              }
              }
            }

            CommandGroup(after: .toolbar) {
                Button("Command Palette…") { model.toggleCommandPalette() }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(endpointWindow != nil)
                Divider()
                Button("Refresh") {
                    if let endpointWindow { endpointWindow.reconnect() }
                    else { model.refreshNow() }
                }
                    .keyboardShortcut("r", modifiers: .command)
            }

            // Scrollback search: route the standard Find actions to whichever
            // terminal pane is first responder — SwiftTerm's TerminalView
            // implements performFindPanelAction: and shows its own find bar.
            CommandGroup(after: .textEditing) {
                Button("Find…") { Self.sendFindAction(.showFindPanel) }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Find Next") { Self.sendFindAction(.next) }
                    .keyboardShortcut("g", modifiers: .command)
                Button("Find Previous") { Self.sendFindAction(.previous) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
            }
        }

        WindowGroup("Rai", id: "independent") {
            // Independent views own their appearance preference.
            EndpointWindow(socketPath: model.activeSocketPath, remoteContext: model.activeRemoteContext)
        }
        .defaultSize(width: 1240, height: 820)
        .commandsRemoved()

        Settings {
            SettingsView(model: RaiApp.sharedModel)
                .preferredColorScheme(settings.appearanceMode.preferredColorScheme)
        }
    }

    /// Sends a standard Find-panel action down the responder chain so it reaches
    /// the focused SwiftTerm terminal view (which handles performFindPanelAction:).
    private static func sendFindAction(_ action: NSFindPanelAction) {
        let item = NSMenuItem()
        item.tag = Int(action.rawValue)
        NSApp.sendAction(
            Selector(("performFindPanelAction:")),
            to: nil,
            from: item
        )
    }
}
