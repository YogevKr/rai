import SwiftUI

@main
struct CorralApp: App {
    @StateObject private var model = CorralModel()

    var body: some Scene {
        WindowGroup {
            CorralRootView(model: model)
                .frame(minWidth: 920, minHeight: 600)
                .preferredColorScheme(.dark)
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

            CommandMenu("Space") {
                Button("New Space") { model.newWorkspace() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Next Space") { model.nextWorkspace() }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Space") { model.prevWorkspace() }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
            }

            CommandGroup(after: .toolbar) {
                Button("Refresh") { model.refreshNow() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}
