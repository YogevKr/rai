import CorralCore
import SwiftUI

struct CorralRootView: View {
    @ObservedObject var model: CorralModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 340)
        } detail: {
            VStack(spacing: 0) {
                PaneHeader(model: model)
                Divider()
                WorkspaceTabBar(model: model)
                Divider()
                PaneLayoutView(model: model)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
    }

}

private struct WorkspaceTabBar: View {
    @ObservedObject var model: CorralModel

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(model.selectedWorkspaceTabs) { tab in
                        Button {
                            model.select(tab: tab)
                        } label: {
                            HStack(spacing: 7) {
                                StatusGlyph(status: tab.agentStatus, compact: true)
                                Text(tab.label)
                                    .lineLimit(1)
                                if tab.paneCount > 1 {
                                    Text("\(tab.paneCount)")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .font(.system(size: 11.5, weight: tab.tabID == model.selectedTabID ? .semibold : .medium))
                            .foregroundStyle(tab.tabID == model.selectedTabID ? .primary : .secondary)
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(
                                        tab.tabID == model.selectedTabID
                                            ? Color.accentColor.opacity(0.16)
                                            : Color.clear
                                    )
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(
                                        tab.tabID == model.selectedTabID
                                            ? Color.accentColor.opacity(0.28)
                                            : Color.clear
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.hidden)
        }
        .frame(height: 38)
        .background(.bar)
    }
}

private struct PaneHeader: View {
    @ObservedObject var model: CorralModel

    var body: some View {
        HStack(spacing: 10) {
            if let pane = model.selectedPane {
                StatusGlyph(status: pane.agentStatus)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pane.terminalTitleStripped ?? pane.agent ?? pane.paneID)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(pane.foregroundCWD ?? pane.cwd)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Text("corral")
                    .font(.headline)
            }
            Spacer()
            ConnectionBadge(state: model.connectionState)
            Button {
                model.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(.bar)
    }
}

private struct ConnectionBadge: View {
    let state: CorralModel.ConnectionState

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .help(help)
    }

    private var color: Color {
        switch state {
        case .connecting: .yellow
        case .connected: .green
        case .disconnected: .red
        }
    }

    private var label: String {
        switch state {
        case .connecting: "Connecting"
        case .connected: "Live"
        case .disconnected: "Offline"
        }
    }

    private var help: String {
        switch state {
        case .connecting:
            "Connecting to Herdr"
        case .connected(let version, let protocolVersion):
            "Herdr \(version), protocol \(protocolVersion)"
        case .disconnected(let message):
            message
        }
    }
}
