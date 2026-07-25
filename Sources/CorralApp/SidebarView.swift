import CorralCore
import SwiftUI

struct SidebarView: View {
    @ObservedObject var model: CorralModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            if let snapshot = model.snapshot {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                        ForEach(snapshot.workspaces.sorted { $0.number < $1.number }) { workspace in
                            let tabs = tabs(in: snapshot, of: workspace)
                            let focused = snapshot.focusedWorkspaceID == workspace.workspaceID
                            if tabs.count <= 1 {
                                // A one-agent space: collapse header + lone tab into a single row.
                                WorkspaceRow(
                                    workspace: workspace,
                                    tab: tabs.first,
                                    focusedInHerdr: focused,
                                    selected: model.selectedTabID == tabs.first?.tabID,
                                    onSelect: { tabs.first.map { model.select(tab: $0) } }
                                )
                                .padding(.top, 8)
                            } else {
                                Section {
                                    ForEach(tabs) { tab in
                                        AgentRow(
                                            label: displayName(for: tab, in: snapshot),
                                            status: tab.agentStatus,
                                            paneCount: tab.paneCount,
                                            selected: model.selectedTabID == tab.tabID,
                                            onSelect: { model.select(tab: tab) }
                                        )
                                    }
                                } header: {
                                    WorkspaceHeader(workspace: workspace, focusedInHerdr: focused)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 16)
                }
                .scrollIndicators(.hidden)
            } else {
                Spacer()
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finding the herd…")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .background(Theme.sidebar)
    }

    private func tabs(in snapshot: SessionSnapshot, of workspace: Workspace) -> [HerdrTab] {
        snapshot.tabs
            .filter { $0.workspaceID == workspace.workspaceID }
            .sorted { $0.number < $1.number }
    }

    // A tab whose label is blank or just its number carries no real title yet;
    // fall back to the pane's terminal title, then the agent kind, then "shell".
    private func displayName(for tab: HerdrTab, in snapshot: SessionSnapshot) -> String {
        let trimmed = tab.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, Int(trimmed) == nil { return trimmed }
        let panes = snapshot.panes.filter { $0.tabID == tab.tabID }
        if let title = panes.compactMap(\.terminalTitleStripped)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return title
        }
        if let agent = panes.compactMap(\.agent)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return agent
        }
        return trimmed.isEmpty ? "shell" : trimmed
    }

    private var header: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Theme.accent, Theme.accent.opacity(0.55)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 16, height: 16)
                .overlay(
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(.white)
                )
                .shadow(color: Theme.accent.opacity(0.4), radius: 4, y: 1)
            Text("corral")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            ConnectionPill(state: model.connectionState)
        }
        .padding(.leading, 78)
        .padding(.trailing, 14)
        .frame(height: 52)
    }
}

// Shared row chrome so workspace-rows and agent-rows are pixel-identical.
private struct SidebarRowChrome: ViewModifier {
    let selected: Bool
    let hovering: Bool

    func body(content: Content) -> some View {
        content
            .padding(.leading, 11)
            .padding(.trailing, 10)
            .frame(height: 34)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        selected
                            ? Theme.accent.opacity(0.16)
                            : (hovering ? Color.white.opacity(0.045) : .clear)
                    )
            }
            .overlay(alignment: .leading) {
                if selected {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Theme.accent)
                        .frame(width: 3, height: 16)
                        .padding(.leading, 1)
                }
            }
    }
}

private struct RepoTag: View {
    let repo: String
    let linked: Bool

    var body: some View {
        HStack(spacing: 3) {
            if linked {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 8))
            }
            Text(repo).lineLimit(1)
        }
        .font(.system(size: 9.5, weight: .medium, design: .rounded))
        .foregroundStyle(Theme.textTertiary)
    }
}

private struct WorkspaceRow: View {
    let workspace: Workspace
    let tab: HerdrTab?
    let focusedInHerdr: Bool
    let selected: Bool
    let onSelect: () -> Void

    @State private var hovering = false

    private var showRepo: Bool {
        guard let repo = workspace.worktree?.repoName else { return false }
        return repo.caseInsensitiveCompare(workspace.label) != .orderedSame
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                StatusDot(status: tab?.agentStatus ?? workspace.agentStatus)
                Text(workspace.label)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                if focusedInHerdr {
                    Circle().fill(Theme.accent).frame(width: 4, height: 4)
                        .help("Focused in Herdr")
                }
                Spacer(minLength: 6)
                if showRepo, let repo = workspace.worktree?.repoName {
                    RepoTag(repo: repo, linked: workspace.worktree?.isLinkedWorktree == true)
                }
            }
            .modifier(SidebarRowChrome(selected: selected, hovering: hovering))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(workspace.worktree?.checkoutPath ?? workspace.label)
    }
}

private struct WorkspaceHeader: View {
    let workspace: Workspace
    let focusedInHerdr: Bool

    private var showRepo: Bool {
        guard let repo = workspace.worktree?.repoName else { return false }
        return repo.caseInsensitiveCompare(workspace.label) != .orderedSame
    }

    var body: some View {
        HStack(spacing: 7) {
            StatusDot(status: workspace.agentStatus, size: 6)
            Text(workspace.label)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            if focusedInHerdr {
                Circle().fill(Theme.accent).frame(width: 4, height: 4)
                    .help("Focused in Herdr")
            }
            Spacer(minLength: 4)
            if showRepo, let repo = workspace.worktree?.repoName {
                RepoTag(repo: repo, linked: workspace.worktree?.isLinkedWorktree == true)
            } else {
                Text("\(workspace.tabCount)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 16)
        .padding(.bottom, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sidebar)
        .help(workspace.worktree?.checkoutPath ?? workspace.label)
    }
}

private struct AgentRow: View {
    let label: String
    let status: AgentStatus
    let paneCount: Int
    let selected: Bool
    let onSelect: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                StatusDot(status: status)
                Text(label)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if paneCount > 1 {
                    HStack(spacing: 3) {
                        Image(systemName: "rectangle.split.2x1")
                        Text("\(paneCount)")
                    }
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                }
            }
            .modifier(SidebarRowChrome(selected: selected, hovering: hovering))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct ConnectionPill: View {
    let state: CorralModel.ConnectionState

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .shadow(color: color.opacity(0.6), radius: 3)
            .help(help)
    }

    private var color: Color {
        switch state {
        case .connecting: Color(hex: 0xF0C33C)
        case .connected: Color(hex: 0x46CE7C)
        case .disconnected: Color(hex: 0xFF6B5E)
        }
    }

    private var help: String {
        switch state {
        case .connecting: "Connecting to Herdr…"
        case .connected(let version, let proto): "Live · Herdr \(version), protocol \(proto)"
        case .disconnected(let message): "Offline · \(message)"
        }
    }
}
