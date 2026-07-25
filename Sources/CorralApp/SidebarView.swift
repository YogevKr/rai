import CorralCore
import SwiftUI

struct SidebarView: View {
    @ObservedObject var model: CorralModel

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            if let snapshot = model.snapshot {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(snapshot.workspaces.sorted(by: workspaceOrder)) { workspace in
                            WorkspaceSection(
                                workspace: workspace,
                                tabs: snapshot.tabs
                                    .filter { $0.workspaceID == workspace.workspaceID }
                                    .sorted(by: tabOrder),
                                selected: model.selectedWorkspace?.workspaceID
                                    == workspace.workspaceID,
                                focusedInHerdr: snapshot.focusedWorkspaceID
                                    == workspace.workspaceID,
                                selectedTabID: model.selectedTabID,
                                onSelect: model.select(tab:)
                            )
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 12)
                }
            } else {
                Spacer()
                ProgressView("Finding the herd…")
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .background(.thinMaterial)
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up.fill")
                .foregroundStyle(.tint)
            Text("corral")
                .font(.system(size: 14, weight: .bold, design: .rounded))
            Spacer()
            if let count = model.snapshot?.workspaces.count {
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
        .padding(.leading, 76)
        .padding(.trailing, 12)
        .frame(height: 48)
        .background(.bar)
    }

    private func workspaceOrder(_ lhs: Workspace, _ rhs: Workspace) -> Bool {
        lhs.number < rhs.number
    }

    private func tabOrder(_ lhs: HerdrTab, _ rhs: HerdrTab) -> Bool {
        lhs.number < rhs.number
    }
}

private struct WorkspaceSection: View {
    let workspace: Workspace
    let tabs: [HerdrTab]
    let selected: Bool
    let focusedInHerdr: Bool
    let selectedTabID: String?
    let onSelect: (HerdrTab) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                StatusGlyph(status: workspace.agentStatus, compact: true)
                Text(workspace.label)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let repo = workspace.worktree?.repoName {
                    HStack(spacing: 3) {
                        if workspace.worktree?.isLinkedWorktree == true {
                            Image(systemName: "point.3.connected.trianglepath.dotted")
                        }
                        Text(repo)
                            .lineLimit(1)
                    }
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(selected ? .secondary : .tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                }
                if focusedInHerdr {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 4, height: 4)
                        .help("Focused in Herdr")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 25)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Color.primary.opacity(0.055) : .clear)
            }
            .overlay(alignment: .leading) {
                if selected {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 2, height: 14)
                }
            }
            .help(workspace.worktree?.checkoutPath ?? workspace.label)

            VStack(spacing: 1) {
                ForEach(tabs) { tab in
                    Button {
                        onSelect(tab)
                    } label: {
                        TabRow(tab: tab, selected: selectedTabID == tab.tabID)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct TabRow: View {
    let tab: HerdrTab
    let selected: Bool

    var body: some View {
        HStack(spacing: 9) {
            StatusGlyph(status: tab.agentStatus)
            Text(tab.label)
                .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1)
            Spacer()
            if tab.paneCount > 1 {
                Label("\(tab.paneCount)", systemImage: "rectangle.split.2x1")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 29)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.18) : .clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(selected ? Color.accentColor.opacity(0.24) : .clear)
        }
    }
}

struct StatusGlyph: View {
    let status: AgentStatus
    var compact = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: compact ? 8 : 9, weight: .bold))
            .foregroundStyle(color)
            .frame(width: compact ? 10 : 13)
            .accessibilityLabel(status.rawValue.capitalized)
    }

    private var symbol: String {
        switch status {
        case .working: "sparkle"
        case .blocked: "exclamationmark.triangle.fill"
        case .done: "checkmark.circle.fill"
        case .idle: "circle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    private var color: Color {
        switch status {
        case .working: .cyan
        case .blocked: .orange
        case .done: .green
        case .idle: .secondary
        case .unknown: .gray.opacity(0.7)
        }
    }
}
