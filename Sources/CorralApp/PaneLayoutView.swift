import CorralCore
import SwiftUI

struct PaneLayoutView: View {
    @ObservedObject var model: CorralModel

    var body: some View {
        if let layout = model.selectedLayout {
            if let tree = PaneLayoutTreeBuilder.build(from: layout) {
                SplitNodeView(node: tree, model: model)
            } else {
                AbsolutePaneLayoutView(layout: layout, model: model)
            }
        } else if let pane = model.visiblePanes.first {
            PaneSurface(paneID: pane.paneID, model: model)
        } else {
            ContentUnavailableView(
                "No pane selected",
                systemImage: "rectangle.split.2x1",
                description: Text("Choose a tab from the sidebar or tab bar.")
            )
        }
    }
}

private struct SplitNodeView: View {
    let node: PaneLayoutNode
    @ObservedObject var model: CorralModel

    var body: some View {
        nodeView(node)
    }

    private func nodeView(_ node: PaneLayoutNode) -> AnyView {
        switch node {
        case .pane(let paneID):
            return AnyView(PaneSurface(paneID: paneID, model: model))
        case .split(_, let direction, let ratio, let first, let second):
            return AnyView(
                GeometryReader { geometry in
                    let availableWidth = max(0, geometry.size.width - 1)
                    let availableHeight = max(0, geometry.size.height - 1)
                    switch direction {
                    case .right:
                        HStack(spacing: 1) {
                            nodeView(first)
                                .frame(width: availableWidth * ratio)
                            nodeView(second)
                                .frame(width: availableWidth * (1 - ratio))
                        }
                    case .down:
                        VStack(spacing: 1) {
                            nodeView(first)
                                .frame(height: availableHeight * ratio)
                            nodeView(second)
                                .frame(height: availableHeight * (1 - ratio))
                        }
                    }
                }
            )
        }
    }
}

private struct AbsolutePaneLayoutView: View {
    let layout: PaneLayoutSnapshot
    @ObservedObject var model: CorralModel

    var body: some View {
        GeometryReader { geometry in
            let widthScale = geometry.size.width / CGFloat(max(layout.area.width, 1))
            let heightScale = geometry.size.height / CGFloat(max(layout.area.height, 1))

            ZStack(alignment: .topLeading) {
                ForEach(layout.panes, id: \.paneID) { pane in
                    PaneSurface(paneID: pane.paneID, model: model)
                        .frame(
                            width: CGFloat(pane.rect.width) * widthScale,
                            height: CGFloat(pane.rect.height) * heightScale
                        )
                        .offset(
                            x: CGFloat(pane.rect.x - layout.area.x) * widthScale,
                            y: CGFloat(pane.rect.y - layout.area.y) * heightScale
                        )
                }
            }
        }
    }
}

private struct PaneSurface: View {
    let paneID: String
    @ObservedObject var model: CorralModel

    private var pane: Pane? {
        model.snapshot?.panes.first { $0.paneID == paneID }
    }

    private var selected: Bool {
        model.selectedPaneID == paneID
    }

    var body: some View {
        VStack(spacing: 0) {
            paneBar
            ZStack {
                Color(red: 0.055, green: 0.063, blue: 0.078)
                TerminalPaneView(
                    paneID: paneID,
                    frame: model.terminalFrame(for: paneID),
                    client: model.client,
                    isFocused: selected
                )
                if model.terminalFrame(for: paneID) == nil {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .background(Color(red: 0.055, green: 0.063, blue: 0.078))
        .contentShape(Rectangle())
        .overlay {
            Rectangle()
                .stroke(
                    selected ? Color.accentColor.opacity(0.9) : Color.white.opacity(0.08),
                    lineWidth: selected ? 2 : 1
                )
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                model.select(paneID: paneID, focusInHerdr: true)
            }
        )
    }

    private var paneBar: some View {
        HStack(spacing: 7) {
            if let pane {
                StatusGlyph(status: pane.agentStatus, compact: true)
                Text(pane.terminalTitleStripped ?? pane.agent ?? pane.paneID)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(pane.paneID)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            } else {
                Text(paneID)
                Spacer()
            }
        }
        .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
        .foregroundStyle(selected ? .primary : .secondary)
        .padding(.horizontal, 8)
        .frame(height: 25)
        .background(
            selected
                ? Color.accentColor.opacity(0.11)
                : Color(nsColor: .controlBackgroundColor).opacity(0.7)
        )
    }
}
