import RaiCore
import SwiftUI
import UniformTypeIdentifiers

private enum RaiMixedPaneDrag {
    static let type = UTType(exportedAs: "gr.krig.rai.mixed-pane")
}

/// Renders one Rai tab. Its slots may belong to different Herdr endpoints.
struct RaiMixedTabView: View {
    @ObservedObject var model: RaiMixedViewModel
    let tabID: UUID
    let endpoints: [MachineEndpoint: RaiMixedEndpointSession]
    @State private var draggedSlotID: UUID?

    private var slots: [RaiPaneSlot] {
        model.composition.tab(id: tabID)?.paneSlots ?? []
    }

    private var columnCount: Int {
        model.composition.tab(id: tabID)?.columnCount ?? 2
    }

    var body: some View {
        Group {
            if slots.isEmpty {
                ContentUnavailableView("No panes in this Rai tab", systemImage: "rectangle.split.2x1")
            } else {
                paneGrid
            }
        }
        .background(Theme.base)
        .toolbar {
            ToolbarItem {
                Picker("Columns", selection: Binding(
                    get: { columnCount },
                    set: { value in
                        guard model.setColumnCount(value, for: tabID) else { return }
                        _ = model.save()
                    }
                )) {
                    ForEach(1...RaiCompositionLimits.maxColumnsPerTab, id: \.self) { value in
                        Text("\(value)").tag(value)
                    }
                }
                .pickerStyle(.menu)
                .help("Columns in this Rai tab")
            }
        }
    }

    private var paneGrid: some View {
        let resolutions = (try? model.resolutions(for: tabID)) ?? []
        return ScrollView {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(minimum: 220)), count: columnCount),
                spacing: 8
            ) {
                ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                    RaiMixedPaneSlotView(
                        slot: slot,
                        resolution: resolutions.indices.contains(index) ? resolutions[index] : .paneIdentityChanged,
                        endpoint: endpoints[slot.source.endpoint],
                        isDragged: draggedSlotID == slot.id
                    )
                    .onDrag {
                        draggedSlotID = slot.id
                        let data = Data(slot.id.uuidString.utf8) as NSData
                        return NSItemProvider(item: data, typeIdentifier: RaiMixedPaneDrag.type.identifier)
                    }
                    .onDrop(
                        of: [RaiMixedPaneDrag.type],
                        delegate: RaiMixedPaneDropDelegate(
                            model: model,
                            tabID: tabID,
                            targetSlotID: slot.id,
                            draggedSlotID: $draggedSlotID,
                            onMove: { _ = model.save() }
                        )
                    )
                }
            }
            .padding(8)
        }
    }
}

private struct RaiMixedPaneSlotView: View {
    let slot: RaiPaneSlot
    let resolution: RaiPaneResolution
    let endpoint: RaiMixedEndpointSession?
    let isDragged: Bool

    var body: some View {
        Group {
            switch resolution {
            case .ready(let target):
                if let endpoint {
                    terminal(target: target, endpoint: endpoint)
                } else {
                    unavailable("Endpoint is offline")
                }
            case .endpointOffline:
                unavailable(endpoint?.error ?? "Endpoint is offline")
            case .paneMissing:
                unavailable("Pane is no longer available")
            case .paneIdentityChanged:
                unavailable("Pane identity changed")
            }
        }
        .frame(minHeight: 220)
        .background(Theme.terminalBG)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusPane, style: .continuous))
        .opacity(isDragged ? 0.45 : 1)
    }

    private func terminal(target: RaiPaneRenderTarget, endpoint: RaiMixedEndpointSession) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(slot.label ?? target.source.paneID)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(target.source.endpoint.session)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider().overlay(Theme.hairline)
            TerminalPaneView(
                terminalID: target.terminalID,
                paneID: target.source.paneID,
                paneCWD: endpoint.pane(paneID: target.source.paneID)?.objectValue?["foreground_cwd"]?.stringValue
                    ?? endpoint.pane(paneID: target.source.paneID)?.objectValue?["cwd"]?.stringValue,
                supportsDirectScrolling: false,
                isFocused: endpoint.snapshot?.focusedPaneID == target.source.paneID,
                pool: endpoint.pool,
                onPlainClick: { endpoint.focus(paneID: target.source.paneID) }
            )
            .padding(8)
        }
    }

    private func unavailable(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Theme.textTertiary)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Text(slot.source.paneID)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RaiMixedPaneDropDelegate: DropDelegate {
    let model: RaiMixedViewModel
    let tabID: UUID
    let targetSlotID: UUID
    @Binding var draggedSlotID: UUID?
    let onMove: () -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedSlotID,
              draggedSlotID != targetSlotID,
              model.movePaneSlot(draggedSlotID, before: targetSlotID, in: tabID) else { return }
        onMove()
    }

    func dropExited(info: DropInfo) {}

    func performDrop(info: DropInfo) -> Bool {
        draggedSlotID = nil
        return true
    }
}
