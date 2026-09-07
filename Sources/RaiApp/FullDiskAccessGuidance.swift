import AppKit
import SwiftUI

/// This records an explanation, never an OS permission grant. There is no
/// protected-file probe: showing help must not itself trigger a privacy prompt.
@MainActor
final class FullDiskAccessGuidance {
    static let shared = FullDiskAccessGuidance()
    private static let shownKey = "fullDiskAccessGuidanceShown"
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Shared by all windows. Existing installations see the explanation once
    /// after upgrading; dismissing it or opening Settings prevents future nags.
    func claimLaunchPresentation() -> Bool {
        guard !defaults.bool(forKey: Self.shownKey) else { return false }
        defaults.set(true, forKey: Self.shownKey)
        return true
    }
}

private struct FullDiskAccessHelpModifier: ViewModifier {
    @Binding var isPresented: Bool
    @State private var settingsOpenFailed = false
    @State private var shouldOpenSettings = false

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented, onDismiss: {
                guard shouldOpenSettings else { return }
                shouldOpenSettings = false
                settingsOpenFailed = !NSWorkspace.shared.open(FullDiskAccessGuidance.settingsURL)
            }) {
                FullDiskAccessDialog(dismiss: {
                    isPresented = false
                }, openSettings: {
                    shouldOpenSettings = true
                    isPresented = false
                })
            }
            .alert("Open System Settings manually", isPresented: $settingsOpenFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Go to Privacy & Security → Full Disk Access. Enable this app, then quit and reopen it.")
            }
    }
}

/// A sheet belongs to Rai's existing window and never creates a Dock item.
private struct FullDiskAccessDialog: View {
    var dismiss: () -> Void
    var openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable()
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Full Disk Access for Rai")
                        .font(.system(size: 19, weight: .semibold))
                    Text("Optional permission")
                        .foregroundStyle(.secondary)
                }
            }

            Text("Commands such as 1Password CLI can cause repeated macOS requests to access data from other apps.")
            Text("Full Disk Access can stop these prompts. It lets Rai and commands running through it access protected files, including Mail and Messages.")

            VStack(alignment: .leading, spacing: 6) {
                Text("1. Open Full Disk Access in System Settings.")
                Text("2. Enable this app, then quit and reopen it.")
            }

            Text("You can keep using Rai without this permission. Review this anytime in Settings → Herdr Server → Mac Privacy.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Not Now", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Open System Settings", action: openSettings)
                    .buttonStyle(.borderedProminent)
            }
        }
        .font(.system(size: 13))
        .padding(24)
        .frame(width: 480, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct FullDiskAccessLaunchModifier: ViewModifier {
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .fullDiskAccessHelp(isPresented: $isPresented)
            .task {
                isPresented = FullDiskAccessGuidance.shared.claimLaunchPresentation()
            }
    }
}

extension View {
    func fullDiskAccessHelp(isPresented: Binding<Bool>) -> some View {
        modifier(FullDiskAccessHelpModifier(isPresented: isPresented))
    }

    func fullDiskAccessLaunchGuidance() -> some View {
        modifier(FullDiskAccessLaunchModifier())
    }
}
