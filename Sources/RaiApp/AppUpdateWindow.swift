import AppKit
import Combine
import SwiftUI

final class AppUpdatePanel: NSPanel {
    var onDismiss: (() -> Void)?

    /// Consume both session-close shortcuts before the app's menu can handle them.
    /// The controller also consumes dismissal while installation is in progress.
    func handleCloseShortcut(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              event.keyCode == 13 || event.charactersIgnoringModifiers?.lowercased() == "w"
        else { return false }
        onDismiss?()
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleCloseShortcut(event) || super.performKeyEquivalent(with: event)
    }
}

/// One app-wide window avoids duplicate sheets when Rai has several windows.
@MainActor
final class AppUpdateWindow {
    private let model: AppUpdateController
    private var window: NSWindow?
    private var subscription: AnyCancellable?
    private var activationObserver: NSObjectProtocol?

    init(model: AppUpdateController) {
        self.model = model
        subscription = model.$isPresented.sink { [weak self] presented in
            // Published emits before the property changes. Use the emitted value.
            if presented { self?.showIfActive() }
            else { self?.window?.orderOut(nil) }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.isPresented else { return }
                self.showIfActive()
            }
        }
    }

    private func showIfActive() {
        guard NSApp.isActive else { return }
        if window == nil {
            let panel = AppUpdatePanel(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 290),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            panel.title = "Rai Update"
            panel.isReleasedWhenClosed = false
            panel.isOpaque = true
            panel.backgroundColor = .windowBackgroundColor
            panel.hidesOnDeactivate = false
            panel.onDismiss = { [weak model] in model?.dismiss() }
            panel.contentView = NSHostingView(rootView: AppUpdateDialog(model: model))
            panel.center()
            window = panel
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

struct AppUpdateDialog: View {
    @ObservedObject var model: AppUpdateController

    private var title: String {
        switch model.phase {
        case .idle, .checking: return "Checking for updates"
        case .available: return "A new Rai version is available"
        case .installing: return "Updating Rai"
        case .upToDate: return "Rai is up to date"
        case .failed: return "Rai could not update"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 18, weight: .semibold))
                    if let release = model.release {
                        Text("Rai \(model.currentVersion) → \(release.version.description)")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
            }
            switch model.phase {
            case .idle, .checking:
                ProgressView().controlSize(.small)
            case .available:
                Text("Update installs Rai and restarts the app. Your agents keep running.")
                Text("Skip hides this version. Future updates will still appear.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            case .installing:
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Downloading and checking the update…")
                }
                Text("Rai will restart when the update is ready. Your agents keep running.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            case .upToDate:
                Text("You have the latest Rai version: \(model.currentVersion).")
            case .failed(let message):
                Text(message).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if model.release != nil {
                    Button("Skip") { model.skip() }
                        .keyboardShortcut(.cancelAction)
                    // No Return shortcut: an automatic notice must not turn a
                    // terminal keystroke into permission to install and restart.
                    Button("Update") { Task { await model.update() } }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Close") { model.dismiss() }
                        .keyboardShortcut(.cancelAction)
                    if case .failed = model.phase {
                        Button("Check Again") { Task { await model.check(manual: true) } }
                    }
                }
            }
            .disabled(model.isInstalling || model.isChecking)
        }
        .font(.system(size: 13))
        .padding(24)
        .frame(width: 460, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .fixedSize(horizontal: false, vertical: true)
    }
}
