import AppKit
import CorralCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let corralPane = UTType(exportedAs: "ai.sawmills.corral.pane")
}

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
                    SplitNodeView(
                        node: tree,
                        model: model,
                        showChrome: isSplit
                    )
                        .padding(isSplit ? 8 : 0)
                } else {
                    AbsolutePaneLayoutView(
                        layout: layout,
                        model: model,
                        showChrome: isSplit
                    )
                        .padding(isSplit ? 8 : 0)
                }
            } else if let pane = model.visiblePanes.first {
                PaneSurface(
                    paneID: pane.paneID,
                    model: model,
                    showChrome: false
                )
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
            return AnyView(
                PaneSurface(
                    paneID: paneID,
                    model: model,
                    showChrome: showChrome
                )
            )
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
                    PaneSurface(
                        paneID: pane.paneID,
                        model: model,
                        showChrome: showChrome
                    )
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
    @State private var dropIndicator: PaneDropIndicator?
    @State private var renamePresented = false
    @State private var processInfoPresented = false

    private var pane: Pane? {
        model.snapshot?.panes.first { $0.paneID == paneID }
    }

    private var selected: Bool {
        model.selectedPaneID == paneID
    }

    private var zoomed: Bool {
        model.selectedLayout?.zoomed == true
            && model.selectedLayout?.focusedPaneID == paneID
    }

    var body: some View {
        GeometryReader { geometry in
            surface
                .overlay { dropOverlay }
                .onDrop(
                    of: [UTType.corralPane],
                    delegate: PaneDropDelegate(
                        targetPaneID: paneID,
                        targetSize: geometry.size,
                        model: model,
                        draggedPaneID: $model.draggedPaneID,
                        indicator: $dropIndicator
                    )
                )
                .animation(.easeOut(duration: 0.12), value: dropIndicator)
                .sheet(isPresented: $renamePresented) {
                    PaneRenameSheet(
                        model: model,
                        paneID: paneID,
                        initialLabel: pane.map(model.displayTitle(for:)) ?? "Terminal"
                    )
                }
                .sheet(isPresented: $processInfoPresented) {
                    PaneProcessInfoSheet(
                        model: model,
                        paneID: paneID,
                        paneTitle: pane.map(model.displayTitle(for:)) ?? "Terminal"
                    )
                }
        }
    }

    private var surface: some View {
        VStack(spacing: 0) {
            if showChrome {
                paneBar
                Divider().overlay(Theme.hairline)
            }
            ZStack {
                Theme.terminalBG
                if let terminalID = pane?.terminalID {
                    TerminalPaneView(
                        terminalID: terminalID,
                        isFocused: selected,
                        pool: model.terminalPool,
                        onPlainClick: {
                            model.select(paneID: paneID, focusInHerdr: true)
                        }
                    )
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }
            }
        }
        .background(Theme.terminalBG)
        .clipShape(RoundedRectangle(cornerRadius: showChrome ? 10 : 0, style: .continuous))
        .overlay {
            if showChrome {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        selected ? Theme.accent.opacity(0.5) : Color.white.opacity(0.045),
                        lineWidth: 1
                    )
            }
        }
        .shadow(
            color: .black.opacity(showChrome ? 0.28 : 0),
            radius: selected ? 16 : 9,
            y: 5
        )
    }

    private var paneBar: some View {
        HStack(spacing: 8) {
            if let pane {
                StatusDot(status: pane.agentStatus, size: 6)
                Text(model.displayTitle(for: pane))
                    .lineLimit(1)
                Spacer(minLength: 4)
            } else {
                Text("Terminal")
                Spacer()
            }

            if zoomed {
                Label("Zoomed", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Theme.accent.opacity(0.13), in: Capsule())
            }

            agentLaunchMenu
        }
        .font(.system(size: 11, weight: selected ? .semibold : .medium))
        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(selected ? Theme.accent.opacity(0.10) : Theme.bar)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.zoomPane(paneID) }
        .onTapGesture { model.select(paneID: paneID, focusInHerdr: true) }
        .contextMenu {
            Button("Rename…") {
                renamePresented = true
            }
            Button("Process Info") {
                processInfoPresented = true
            }
        }
        .onDrag {
            model.draggedPaneID = paneID
            let provider = NSItemProvider()
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.corralPane.identifier,
                visibility: .ownProcess
            ) { completion in
                completion(Data(paneID.utf8), nil)
                return nil
            }
            return provider
        }
    }

    private var agentLaunchMenu: some View {
        Menu {
            Button("Claude — Split Right") {
                model.launchAgent(.claude, direction: .right, from: paneID)
            }
            Button("Claude — Split Down") {
                model.launchAgent(.claude, direction: .down, from: paneID)
            }
            Divider()
            Button("Codex — Split Right") {
                model.launchAgent(.codex, direction: .right, from: paneID)
            }
            Button("Codex — Split Down") {
                model.launchAgent(.codex, direction: .down, from: paneID)
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Split and launch an agent")
    }

    @ViewBuilder
    private var dropOverlay: some View {
        switch dropIndicator {
        case .swap:
            RoundedRectangle(cornerRadius: showChrome ? 8 : 0, style: .continuous)
                .fill(Theme.accent.opacity(0.18))
                .stroke(Theme.accent, lineWidth: 3)
                .allowsHitTesting(false)
        case .right:
            ZStack(alignment: .trailing) {
                RoundedRectangle(cornerRadius: showChrome ? 8 : 0, style: .continuous)
                    .stroke(Theme.accent.opacity(0.8), lineWidth: 2)
                Rectangle()
                    .fill(Theme.accent)
                    .frame(width: 6)
                    .padding(.vertical, showChrome ? 5 : 0)
            }
            .allowsHitTesting(false)
        case .down:
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: showChrome ? 8 : 0, style: .continuous)
                    .stroke(Theme.accent.opacity(0.8), lineWidth: 2)
                Rectangle()
                    .fill(Theme.accent)
                    .frame(height: 6)
                    .padding(.horizontal, showChrome ? 5 : 0)
            }
            .allowsHitTesting(false)
        case nil:
            EmptyView()
        }
    }
}

private struct PaneRenameSheet: View {
    @ObservedObject var model: CorralModel
    let paneID: String

    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @FocusState private var labelFocused: Bool

    init(model: CorralModel, paneID: String, initialLabel: String) {
        self.model = model
        self.paneID = paneID
        _label = State(initialValue: initialLabel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Rename Pane")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            VStack(alignment: .leading, spacing: 7) {
                TextField("Name", text: $label)
                    .textFieldStyle(.roundedBorder)
                    .focused($labelFocused)
                    .onSubmit(commit)
                Text("Leave empty to clear the pane name.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: commit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 380)
        .background(Theme.raised)
        .onAppear { labelFocused = true }
        .onExitCommand { dismiss() }
    }

    private func commit() {
        model.renamePane(paneID: paneID, to: label)
        dismiss()
    }
}

private struct PaneProcessInfoSheet: View {
    @ObservedObject var model: CorralModel
    let paneID: String
    let paneTitle: String

    @Environment(\.dismiss) private var dismiss
    @State private var processInfo: PaneProcessInfo?
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Process Info")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(paneTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            Group {
                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading process information…")
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 110)
                } else if let processInfo {
                    processDetails(processInfo)
                } else {
                    VStack(spacing: 10) {
                        Text("Process information is unavailable.")
                            .foregroundStyle(Theme.textSecondary)
                        Button("Try Again") {
                            Task { await load() }
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 110)
                }
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 500)
        .background(Theme.raised)
        .task { await load() }
        .onExitCommand { dismiss() }
    }

    private func processDetails(_ info: PaneProcessInfo) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 20) {
                metadata(label: "Shell PID", value: String(info.shellPID))
                metadata(label: "TTY", value: info.tty ?? "—")
            }

            Divider().overlay(Theme.hairline)

            if info.foregroundProcesses.isEmpty {
                Text("No foreground processes.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 64)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(info.foregroundProcesses, id: \.pid) { process in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 7) {
                                    Text(process.name)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Theme.textPrimary)
                                    Text("PID \(process.pid)")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(Theme.textTertiary)
                                }
                                Text(process.cmdline)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(Theme.textSecondary)
                                    .textSelection(.enabled)
                                Text(process.cwd)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(Theme.textTertiary)
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
    }

    private func metadata(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
        }
    }

    private func load() async {
        isLoading = true
        processInfo = await model.processInfo(for: paneID)
        isLoading = false
    }
}

private enum PaneDropIndicator: Equatable {
    case swap
    case right
    case down
}

private struct PaneDropDelegate: DropDelegate {
    let targetPaneID: String
    let targetSize: CGSize
    @ObservedObject var model: CorralModel
    @Binding var draggedPaneID: String?
    @Binding var indicator: PaneDropIndicator?

    func validateDrop(info: DropInfo) -> Bool {
        guard info.hasItemsConforming(to: [UTType.corralPane.identifier]),
              let sourcePaneID = draggedPaneID else {
            return false
        }
        return sourcePaneID != targetPaneID
    }

    func dropEntered(info: DropInfo) {
        indicator = proposedIndicator(at: info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else {
            indicator = nil
            return DropProposal(operation: .cancel)
        }
        indicator = proposedIndicator(at: info.location)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        indicator = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let sourcePaneID = draggedPaneID,
              let proposed = proposedIndicator(at: info.location) else {
            indicator = nil
            return false
        }
        let direction: SplitDirection = proposed == .down ? .down : .right
        model.dropPane(
            sourcePaneID: sourcePaneID,
            onto: targetPaneID,
            moveDirection: direction
        )
        indicator = nil
        draggedPaneID = nil
        return true
    }

    private func proposedIndicator(at location: CGPoint) -> PaneDropIndicator? {
        guard let sourcePaneID = draggedPaneID,
              sourcePaneID != targetPaneID,
              let source = model.snapshot?.panes.first(where: { $0.paneID == sourcePaneID }),
              let target = model.snapshot?.panes.first(where: { $0.paneID == targetPaneID }) else {
            return nil
        }
        if source.tabID == target.tabID {
            return .swap
        }

        let distanceToRight = max(0, targetSize.width - location.x)
        let distanceToBottom = max(0, targetSize.height - location.y)
        return distanceToRight <= distanceToBottom ? .right : .down
    }
}
