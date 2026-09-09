import RaiCore
import SwiftUI

struct EndpointAgentViewRows: View {
    let snapshot: HerdrEndpointSnapshot
    let busy: Bool
    let select: (String) -> Void
    var palette = EndpointThemePalette(theme: "", dark: false)

    var body: some View {
        Section {
            if snapshot.agentOrder.isEmpty { Text("No agents match this view.").foregroundStyle(palette.secondary) }
            ForEach(snapshot.agentOrder, id: \.self) { paneID in
                if let agent = snapshot.agents.first(where: { $0.objectValue?["pane_id"]?.stringValue == paneID }) {
                    Button { select(paneID) } label: {
                        HStack {
                            EndpointMetadataRows(record: agent, kind: .agent, snapshot: snapshot, foreground: palette.foreground)
                            Spacer()
                            if snapshot.focusedPaneID == paneID { Image(systemName: "checkmark") }
                        }
                    }.disabled(busy)
                    .foregroundStyle(palette.foreground)
                    .listRowBackground(snapshot.focusedPaneID == paneID
                        ? palette.color("active_row_bg", fallback: .clear) : palette.sidebar)
                }
            }
        } header: {
            Text(snapshot.agentViewLabel ?? "Agents").foregroundStyle(palette.secondary)
        }
    }
}

struct EndpointTabStatus: View {
    let snapshot: HerdrEndpointSnapshot

    var body: some View {
        HStack(spacing: 4) {
            ForEach(snapshot.tabBarRight.indices, id: \.self) { index in
                if index > 0 { Text(snapshot.tabBarRightSeparator).foregroundStyle(.secondary) }
                let segment = snapshot.tabBarRight[index].objectValue ?? [:]
                Text(segment["text"]?.stringValue ?? "")
                    .foregroundStyle(segment["accent"] == .bool(true) ? Color.accentColor : Color.secondary)
            }
        }.font(.caption).lineLimit(1).accessibilityElement(children: .combine)
    }
}
