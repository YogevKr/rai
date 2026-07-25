import CorralCore
import SwiftUI

struct CommandPaletteView: View {
    @ObservedObject var model: CorralModel

    @State private var query = ""
    @State private var selectedID: String?
    @FocusState private var searchFocused: Bool

    private var results: [CommandPaletteItem] {
        FuzzyMatcher.ranked(model.commandPaletteItems, query: query, text: \.label)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                TextField("Find any agent or space…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textPrimary)
                    .focused($searchFocused)
                    .onSubmit(selectCurrentResult)
            }
            .padding(.horizontal, 17)
            .frame(height: 52)

            Divider().overlay(Theme.hairlineStrong)

            ScrollViewReader { proxy in
                ScrollView {
                    if results.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 20, weight: .light))
                            Text("No matching agents or spaces")
                                .font(.system(size: 12.5, weight: .medium))
                        }
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 42)
                    } else {
                        LazyVStack(spacing: 3) {
                            ForEach(results) { item in
                                resultRow(item)
                                    .id(item.id)
                            }
                        }
                        .padding(7)
                    }
                }
                .frame(maxHeight: 390)
                .onChange(of: selectedID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }

            Divider().overlay(Theme.hairline)
            HStack(spacing: 12) {
                keyHint("↑↓", label: "navigate")
                keyHint("↩", label: "open")
                keyHint("esc", label: "close")
                Spacer()
                Text("\(results.count) result\(results.count == 1 ? "" : "s")")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
        }
        .frame(width: 590)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Theme.raised)
                .shadow(color: .black.opacity(0.5), radius: 28, y: 14)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Theme.hairlineStrong, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .onAppear {
            selectedID = results.first?.id
        }
        .task {
            searchFocused = true
        }
        .onChange(of: query) { _, _ in
            selectedID = results.first?.id
        }
        .onChange(of: model.commandPaletteItems) { _, _ in
            if !results.contains(where: { $0.id == selectedID }) {
                selectedID = results.first?.id
            }
        }
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .onExitCommand {
            model.closeCommandPalette()
        }
    }

    private func resultRow(_ item: CommandPaletteItem) -> some View {
        Button {
            model.jump(to: item)
        } label: {
            HStack(spacing: 11) {
                StatusDot(status: item.status)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(item.isWorkspace ? "Space · \(item.workspaceLabel)" : item.workspaceLabel)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
                Text(item.isWorkspace ? "SPACE" : "AGENT")
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .tracking(0.5)
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 47)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        selectedID == item.id
                            ? Theme.accent.opacity(0.17)
                            : Color.clear
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { selectedID = item.id }
        }
    }

    private func keyHint(_ key: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.07))
                )
            Text(label)
        }
        .font(.system(size: 9.5))
        .foregroundStyle(Theme.textTertiary)
    }

    private func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        let current = selectedID.flatMap { id in
            results.firstIndex(where: { $0.id == id })
        } ?? 0
        let next = min(max(current + delta, 0), results.count - 1)
        selectedID = results[next].id
    }

    private func selectCurrentResult() {
        guard let item = results.first(where: { $0.id == selectedID }) ?? results.first else {
            return
        }
        model.jump(to: item)
    }
}
