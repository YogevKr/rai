import SwiftUI

@main
struct CorralApp: App {
    @StateObject private var model = CorralModel()

    var body: some Scene {
        WindowGroup {
            CorralRootView(model: model)
                .frame(minWidth: 860, minHeight: 560)
                .task {
                    model.start()
                }
        }
        .defaultSize(width: 1180, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("Refresh") {
                    model.refreshNow()
                }
                .keyboardShortcut("r")
            }
        }
    }
}
