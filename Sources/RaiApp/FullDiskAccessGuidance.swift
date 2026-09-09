import AppKit
import SwiftUI

/// Inspect a failed operation's error, never probe protected files for permission.
enum FullDiskAccessGuidance {
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!
    static func isAccessFailure(_ error: Error?) -> Bool {
        var current = error as NSError?
        for _ in 0..<8 {
            guard let failure = current else { return false }
            if failure.domain == NSCocoaErrorDomain,
               [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(failure.code) {
                return true
            }
            if failure.domain == NSPOSIXErrorDomain,
               [Int(EACCES), Int(EPERM)].contains(failure.code) {
                return true
            }
            current = failure.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}

struct FullDiskAccessFailureHelp: View {
    let error: Error?
    @State private var isPresented = false

    var body: some View {
        if FullDiskAccessGuidance.isAccessFailure(error) {
            Button("File Access Help…") { isPresented = true }
                .fullDiskAccessHelp(isPresented: $isPresented)
        }
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

            Text("If macOS denies file access, check the file's permissions first. Full Disk Access can help with protected files.")
            Text("This permission lets Rai and commands running through it access protected files, including Mail and Messages.")

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

extension View {
    func fullDiskAccessHelp(isPresented: Binding<Bool>) -> some View {
        modifier(FullDiskAccessHelpModifier(isPresented: isPresented))
    }

}
