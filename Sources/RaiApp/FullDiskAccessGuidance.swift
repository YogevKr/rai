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
    static let message = """
        Commands such as 1Password CLI can cause repeated macOS requests to access data from other apps.
        Full Disk Access can prevent these requests.

        This permission is optional. It lets Rai and commands running through it access protected files, including Mail, Messages, and other apps’ data.

        To enable it, open System Settings → Privacy & Security → Full Disk Access. Enable this app, then quit and reopen it.

        You can keep using Rai without this permission. Review this help anytime in Rai Settings → Herdr Server → Mac Privacy.
        """

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

    func body(content: Content) -> some View {
        content
            .alert("Full Disk Access for Rai", isPresented: $isPresented) {
                Button("Open System Settings") {
                    settingsOpenFailed = !NSWorkspace.shared.open(FullDiskAccessGuidance.settingsURL)
                }
                Button("Not Now", role: .cancel) {}
            } message: {
                Text(FullDiskAccessGuidance.message)
            }
            .alert("Open System Settings manually", isPresented: $settingsOpenFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Go to Privacy & Security → Full Disk Access. Enable this app, then quit and reopen it.")
            }
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
