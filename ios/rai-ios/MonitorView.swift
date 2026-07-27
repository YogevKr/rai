import RaiCore
import SwiftUI

struct MonitorView: View {
    @ObservedObject var connection: BridgeConnection
    let forgetPairing: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if let snapshot = connection.snapshot {
                    herdList(snapshot)
                } else {
                    ContentUnavailableView {
                        Label("Waiting for the herd", systemImage: "antenna.radiowaves.left.and.right")
                    } description: {
                        Text(connection.status.label)
                    } actions: {
                        if !connection.status.isConnected {
                            Button("Retry") { connection.retryNow() }
                        }
                    }
                }
            }
            .navigationTitle("rai")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Reconnect") { connection.retryNow() }
                        Button("Forget Mac", role: .destructive, action: forgetPairing)
                    } label: {
                        ConnectionBadge(status: connection.status)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !connection.status.isConnected {
                    HStack {
                        Image(systemName: "wifi.exclamationmark")
                        Text(connection.status.label)
                            .lineLimit(1)
                        Spacer()
                        Button("Retry") { connection.retryNow() }
                    }
                    .font(.footnote)
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                    .background(.bar)
                }
            }
        }
    }

    private func herdList(_ snapshot: SessionSnapshot) -> some View {
        List {
            ForEach(snapshot.workspaces) { workspace in
                Section {
                    let tabs = snapshot.tabs.filter { $0.workspaceID == workspace.workspaceID }
                    ForEach(tabs) { tab in
                        TabGroup(
                            tab: tab,
                            panes: snapshot.panes.filter { $0.tabID == tab.tabID },
                            connection: connection
                        )
                    }
                } header: {
                    HStack {
                        Text(workspace.label.isEmpty ? "Space \(workspace.number)" : workspace.label)
                        Spacer()
                        StatusPill(status: workspace.agentStatus)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { connection.retryNow() }
    }
}

private struct TabGroup: View {
    let tab: HerdrTab
    let panes: [Pane]
    @ObservedObject var connection: BridgeConnection

    var body: some View {
        DisclosureGroup {
            ForEach(panes) { pane in
                NavigationLink {
                    PanePlaceholder(pane: pane)
                        .onAppear { connection.selectAndFocus(paneID: pane.paneID) }
                } label: {
                    PaneRow(pane: pane)
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: tab.focused ? "rectangle.fill" : "rectangle")
                    .foregroundStyle(.secondary)
                Text(tab.label.isEmpty ? "Tab \(tab.number)" : tab.label)
                    .font(.headline)
                Spacer()
                StatusPill(status: tab.agentStatus)
            }
            .padding(.vertical, 4)
        }
    }
}

private struct PaneRow: View {
    let pane: Pane

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(pane.agent ?? pane.terminalTitleStripped ?? "Pane")
                    .font(.body)
                Text(pane.foregroundCWD ?? pane.cwd)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            StatusPill(status: pane.agentStatus)
        }
        .padding(.vertical, 2)
    }
}

private struct PanePlaceholder: View {
    let pane: Pane

    var body: some View {
        ContentUnavailableView {
            Label(pane.agent ?? "Agent", systemImage: "terminal")
        } description: {
            Text("Terminal viewing and input arrive in Session 2b.")
        }
        .navigationTitle(pane.terminalTitleStripped ?? "Pane")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ConnectionBadge: View {
    let status: BridgeConnection.Status

    var body: some View {
        Label(status.label, systemImage: status.isConnected ? "wifi" : "wifi.exclamationmark")
            .labelStyle(.iconOnly)
            .foregroundStyle(status.isConnected ? Color.green : Color.secondary)
            .accessibilityLabel(status.label)
    }
}

private struct StatusPill: View {
    let status: AgentStatus

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(label)")
    }

    private var label: String {
        switch status {
        case .idle: "Idle"
        case .working: "Working"
        case .blocked: "Needs you"
        case .done: "Done"
        case .unknown: "Unknown"
        }
    }

    private var color: Color {
        switch status {
        case .idle: .primary
        case .working: .blue
        case .blocked: .orange
        case .done: .green
        case .unknown: .secondary
        }
    }
}
