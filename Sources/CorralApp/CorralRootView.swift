import CorralCore
import SwiftUI

struct CorralRootView: View {
    @ObservedObject var model: CorralModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 232, ideal: 276, max: 360)
        } detail: {
            VStack(spacing: 0) {
                PaneHeader(model: model)
                Divider().overlay(Theme.hairline)
                PaneLayoutView(model: model)
            }
            .background(Theme.base)
        }
        .navigationSplitViewStyle(.balanced)
        .preferredColorScheme(.dark)
    }
}

private struct PaneHeader: View {
    @ObservedObject var model: CorralModel

    var body: some View {
        HStack(spacing: 12) {
            if let pane = model.selectedPane {
                StatusDot(status: pane.agentStatus, size: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pane.terminalTitleStripped ?? pane.agent ?? pane.paneID)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(Theme.statusLabel(pane.agentStatus))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.status(pane.agentStatus))
                        if let workspace = model.selectedWorkspace {
                            dot
                            Text(workspace.label)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }
                        dot
                        Text(pane.foregroundCWD ?? pane.cwd)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            } else {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(Theme.textTertiary)
                Text("corral")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 12)
            HeaderButton(system: "arrow.clockwise", help: "Refresh") { model.refreshNow() }
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
        .background(Theme.bar)
    }

    private var dot: some View {
        Text("·").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
    }
}

private struct HeaderButton: View {
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
