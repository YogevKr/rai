import RaiCore
import SwiftUI

/// Renders one Rai tab. Its slots may belong to different Herdr endpoints.
struct RaiMixedTabView: View {
    @ObservedObject var model: RaiMixedViewModel
    let tabID: UUID
    let endpoints: [MachineEndpoint: RaiMixedEndpointSession]

    private var slots: [RaiPaneSlot] {
        model.composition.tab(id: tabID)?.paneSlots ?? []
    }

    var body: some View {
        Group {
            if slots.isEmpty {
                ContentUnavailableView("No panes in this Rai tab", systemImage: "rectangle.split.2x1")
            } else if slots.count == 1, let slot = slots.first {
                singlePane(slot)
            } else {
                paneGrid
            }
        }
        .background(Theme.base)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func singlePane(_ slot: RaiPaneSlot) -> some View {
        RaiMixedPaneSlotView(
            slot: slot,
            position: 1,
            resolution: (try? model.resolutions(for: tabID))?.first ?? .paneIdentityChanged,
            endpoint: endpoints[slot.source.endpoint]
        )
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var paneGrid: some View {
        let resolutions = (try? model.resolutions(for: tabID)) ?? []
        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(paneRows.enumerated()), id: \.offset) { rowIndex, row in
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(Array(row.enumerated()), id: \.element.id) { columnIndex, slot in
                            let index = rowIndex * 2 + columnIndex
                            RaiMixedPaneSlotView(
                                slot: slot,
                                position: index + 1,
                                resolution: resolutions.indices.contains(index) ? resolutions[index] : .paneIdentityChanged,
                                endpoint: endpoints[slot.source.endpoint]
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var paneRows: [[RaiPaneSlot]] {
        stride(from: 0, to: slots.count, by: 2).map { start in
            Array(slots[start..<min(start + 2, slots.count)])
        }
    }
}

private struct RaiMixedPaneSlotView: View {
    let slot: RaiPaneSlot
    let position: Int
    let resolution: RaiPaneResolution
    let endpoint: RaiMixedEndpointSession?

    private var displayLabel: String {
        let label = slot.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return label.isEmpty ? "Pane \(position)" : label
    }

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
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 220)
        .background(Theme.terminalBG)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusPane, style: .continuous))
    }

    private func terminal(target: RaiPaneRenderTarget, endpoint: RaiMixedEndpointSession) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(displayLabel)
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
            Text(displayLabel)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
