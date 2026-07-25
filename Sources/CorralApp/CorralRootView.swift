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
                terminalContent
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private var terminalContent: some View {
        if let paneID = model.selectedPaneID {
            ZStack {
                Color(red: 0.055, green: 0.063, blue: 0.078)
                TerminalPaneView(
                    paneID: paneID,
                    frame: model.terminalFrame,
                    client: model.client
                )
                if model.terminalFrame == nil {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        } else {
            ContentUnavailableView(
                "No pane selected",
                systemImage: "rectangle.split.2x1",
                description: Text("Choose a tab from the sidebar.")
            )
        }
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
