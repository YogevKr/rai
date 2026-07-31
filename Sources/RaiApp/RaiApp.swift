import AppKit
import SwiftUI

@main
struct RaiApp: App {
    @MainActor static let sharedModel = RaiModel()

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = RaiApp.sharedModel
    @StateObject private var settings = SettingsStore.shared

    var body: some Scene {
        WindowGroup {
            RaiRootView(model: model)
                .frame(minWidth: 920, minHeight: 600)
                .preferredColorScheme(settings.appearanceMode.preferredColorScheme)
                .task {
                    model.start()
                }
        }
        .defaultSize(width: 1240, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandMenu("Tab") {
                Button("New Tab") { model.newTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Reopen Closed Tab") { model.reopenClosedTab() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(!model.canReopenClosedTab)
                Button("Close Tab") { model.closeTab() }
                    .keyboardShortcut("w", modifiers: .command)
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

            CommandMenu("Pane") {
                Button("Split Right") { model.splitRight() }
                    .keyboardShortcut("d", modifiers: .command)
                Button("Split Down") { model.splitDown() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Close Pane") { model.closePane() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
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
            }

            CommandMenu("Space") {
                Button("New Space") { model.newWorkspace() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Next Space") { model.nextWorkspace() }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Space") { model.prevWorkspace() }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
            }

            CommandGroup(after: .toolbar) {
                Button("Command Palette…") { model.toggleCommandPalette() }
                    .keyboardShortcut("k", modifiers: .command)
                Divider()
                Button("Refresh") { model.refreshNow() }
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
