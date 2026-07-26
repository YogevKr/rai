import RaiCore
import SwiftUI

struct RaiRootView: View {
    @ObservedObject var model: RaiModel

    var body: some View {
        ZStack {
            NavigationSplitView {
                SidebarView(model: model)
                    .navigationSplitViewColumnWidth(min: 232, ideal: 276, max: 360)
            } detail: {
                // No header — the panes fill the whole screen. The selected agent's
                // details (status · space · cwd) live in the sidebar tab row.
                PaneLayoutView(model: model)
                    .background(Theme.base)
            }

            if model.isCommandPalettePresented {
                Color.black.opacity(0.42)
                    .ignoresSafeArea()
                    .onTapGesture { model.closeCommandPalette() }
                CommandPaletteView(model: model)
                    .padding(.horizontal, 28)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .navigationSplitViewStyle(.balanced)
        .background(WindowConfigurator())
        .preferredColorScheme(.dark)
        .animation(.easeOut(duration: 0.12), value: model.isCommandPalettePresented)
    }
}

struct BroadcastSheet: View {
    @ObservedObject var model: RaiModel

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var confirmation: String?
    @State private var confirmationSequence = 0
    @FocusState private var textFocused: Bool

    private var paneCount: Int { model.visiblePanes.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Broadcast Input")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Send the same command to every pane in this tab.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }

            TextField("Command", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($textFocused)
                .onSubmit(send)

            HStack {
                if let confirmation {
                    Label(confirmation, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.status(.working))
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(sendButtonTitle, action: send)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || paneCount == 0
                    )
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(Theme.raised)
        .onAppear { textFocused = true }
        .onExitCommand { dismiss() }
    }

    private var sendButtonTitle: String {
        "Send to all \(paneCount) \(paneCount == 1 ? "pane" : "panes")"
    }

    private func send() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              paneCount > 0 else {
            return
        }
        let count = paneCount
        model.broadcast(text: text)
        text = ""
        confirmation = "Sent to \(count) \(count == 1 ? "pane" : "panes")"
        confirmationSequence += 1
        let sequence = confirmationSequence
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard sequence == confirmationSequence else { return }
            confirmation = nil
        }
    }
}

struct HeaderButton: View {
    let system: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hovering ? Color.white.opacity(0.06) : .clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
