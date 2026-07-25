import AppKit
import CorralCore
import SwiftUI

struct PaneLayoutView: View {
    @ObservedObject var model: CorralModel

    // Per-pane chrome only earns its space when a tab is split; a lone pane
    // is already fully described by the header above it.
    private var isSplit: Bool { model.visiblePanes.count > 1 }

    var body: some View {
        Group {
            if let layout = model.selectedLayout,
               model.visiblePanes.isEmpty == false {
                if let tree = PaneLayoutTreeBuilder.build(from: layout) {
                    SplitNodeView(node: tree, model: model, showChrome: isSplit)
                        .padding(isSplit ? 8 : 0)
                } else {
                    AbsolutePaneLayoutView(layout: layout, model: model, showChrome: isSplit)
                        .padding(isSplit ? 8 : 0)
                }
            } else if let pane = model.visiblePanes.first {
                PaneSurface(paneID: pane.paneID, model: model, showChrome: false)
            } else {
                EmptyPaneState()
            }
        }
        .background(Theme.base)
    }
}

private struct EmptyPaneState: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            VStack(spacing: 5) {
                Text("No agent selected")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Text("Pick one from the sidebar to open its session.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.base)
    }
}

private struct SplitNodeView: View {
    let node: PaneLayoutNode
    @ObservedObject var model: CorralModel
    let showChrome: Bool

    var body: some View {
        nodeView(node)
    }

    private func nodeView(_ node: PaneLayoutNode) -> AnyView {
        switch node {
        case .pane(let paneID):
            return AnyView(PaneSurface(paneID: paneID, model: model, showChrome: showChrome))
        case .split(let id, let direction, let ratio, let first, let second):
            return AnyView(
                SplitContainer(
                    model: model,
                    splitID: id,
                    direction: direction,
                    ratio: ratio,
                    firstPaneID: first.paneIDs.first ?? "",
                    secondPaneID: second.paneIDs.first ?? "",
                    first: nodeView(first),
                    second: nodeView(second)
                )
            )
        }
    }
}

private struct SplitContainer: View {
    @ObservedObject var model: CorralModel
    let splitID: String
    let direction: SplitDirection
    let ratio: Double
    let firstPaneID: String
    let secondPaneID: String
    let first: AnyView
    let second: AnyView

    @State private var dragStart: Double?
    @State private var hovering = false
    private let handle: CGFloat = 8

    private var effectiveRatio: Double { model.dragRatios[splitID] ?? ratio }

    var body: some View {
        GeometryReader { geometry in
            let ratio = effectiveRatio
            let availableWidth = max(0, geometry.size.width - handle)
            let availableHeight = max(0, geometry.size.height - handle)
            switch direction {
            case .right:
                HStack(spacing: 0) {
                    first.frame(width: availableWidth * ratio)
                    divider(vertical: true, size: geometry.size)
                    second.frame(width: availableWidth * (1 - ratio))
                }
            case .down:
                VStack(spacing: 0) {
                    first.frame(height: availableHeight * ratio)
                    divider(vertical: false, size: geometry.size)
                    second.frame(height: availableHeight * (1 - ratio))
                }
            }
        }
    }

    private func divider(vertical: Bool, size: CGSize) -> some View {
        let active = hovering || dragStart != nil
        return Rectangle()
            .fill(Color.clear)
            .frame(width: vertical ? handle : nil, height: vertical ? nil : handle)
            .frame(maxWidth: vertical ? nil : .infinity, maxHeight: vertical ? .infinity : nil)
            .overlay(
                Rectangle()
                    .fill(active ? Theme.accent.opacity(0.9) : Theme.hairlineStrong)
                    .frame(width: vertical ? (active ? 2 : 1) : nil,
                           height: vertical ? nil : (active ? 2 : 1))
            )
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside {
                    (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
                } else if dragStart == nil {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStart ?? ratio
                        if dragStart == nil { dragStart = start }
                        let available = vertical
                            ? max(1, size.width - handle)
                            : max(1, size.height - handle)
                        let move = vertical ? value.translation.width : value.translation.height
                        model.dragRatios[splitID] = min(0.9, max(0.1, start + move / available))
                    }
                    .onEnded { _ in
                        let start = dragStart ?? ratio
                        let final = model.dragRatios[splitID] ?? start
                        model.commitSplitRatio(
                            splitID: splitID,
                            direction: direction,
                            firstPaneID: firstPaneID,
                            secondPaneID: secondPaneID,
                            delta: final - start
                        )
                        dragStart = nil
                        if !hovering { NSCursor.arrow.set() }
                    }
            )
    }
}

private struct AbsolutePaneLayoutView: View {
    let layout: PaneLayoutSnapshot
    @ObservedObject var model: CorralModel
    let showChrome: Bool

    var body: some View {
        GeometryReader { geometry in
            let widthScale = geometry.size.width / CGFloat(max(layout.area.width, 1))
            let heightScale = geometry.size.height / CGFloat(max(layout.area.height, 1))

            ZStack(alignment: .topLeading) {
                ForEach(layout.panes, id: \.paneID) { pane in
                    PaneSurface(paneID: pane.paneID, model: model, showChrome: showChrome)
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
    let showChrome: Bool

    private var pane: Pane? {
        model.snapshot?.panes.first { $0.paneID == paneID }
    }

    private var selected: Bool {
        model.selectedPaneID == paneID
    }

    var body: some View {
        VStack(spacing: 0) {
            if showChrome {
                paneBar
                Divider().overlay(Theme.hairline)
            }
            ZStack {
                Theme.terminalBG
                if let terminalID = pane?.terminalID {
                    TerminalPaneView(terminalID: terminalID, isFocused: selected)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .id(terminalID)
                }
            }
        }
        .background(Theme.terminalBG)
        .clipShape(RoundedRectangle(cornerRadius: showChrome ? 8 : 0, style: .continuous))
        .overlay {
            if showChrome {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        selected ? Theme.accent.opacity(0.85) : Theme.hairlineStrong,
                        lineWidth: selected ? 1.5 : 1
                    )
            }
        }
    }

    // Click-to-focus lives on the split pane-bar only, so the terminal area is
    // left entirely to SwiftTerm for text selection and mouse reporting.
    private var paneBar: some View {
        HStack(spacing: 8) {
            if let pane {
                StatusDot(status: pane.agentStatus, size: 6)
                Text(pane.terminalTitleStripped ?? pane.agent ?? pane.paneID)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(pane.paneID)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                Text(paneID)
                Spacer()
            }
        }
        .font(.system(size: 11, weight: selected ? .semibold : .medium))
        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(selected ? Theme.accent.opacity(0.10) : Theme.bar)
        .contentShape(Rectangle())
        .onTapGesture { model.select(paneID: paneID, focusInHerdr: true) }
    }
}
