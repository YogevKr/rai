import AppKit
import RaiCore
import SwiftUI

struct CommandPaletteView: View {
    @ObservedObject var model: RaiModel

    @FocusState private var searchFocused: Bool
    @State private var keyMonitor: Any?

    private var results: [CommandPaletteItem] { model.paletteResults }

    private var highlighted: CommandPaletteItem? {
        results.first { $0.id == model.paletteSelectedID } ?? results.first
    }

    private func supports(_ action: CommandPaletteItem.Action) -> Bool {
        guard let item = highlighted else { return false }
        return PaletteActionDecision.supports(
            action,
            kind: item.kind,
            hasPath: !(item.matchPath ?? "").isEmpty,
            isRemote: model.remoteTarget != nil
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                TextField("Find any agent, space, or repo…", text: $model.paletteQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textPrimary)
                    .focused($searchFocused)
                    .onSubmit { model.paletteActivate() }
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
                            Text("No matching agents, spaces, or repos")
                                .font(.system(size: 12.5, weight: .medium))
                        }
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 42)
                    } else {
                        LazyVStack(spacing: 3) {
                            ForEach(results) { item in
                                resultRow(item).id(item.id)
                            }
                        }
                        .padding(7)
                    }
                }
                .frame(maxHeight: 390)
                // Follows the keyboard only. Scrolling on every selection
                // change would chase hover too, and centering a hovered row
                // moves the list under the cursor — see paletteScrollTarget.
                .onChange(of: model.paletteScrollTarget) { _, id in
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
                // Only advertise a modifier the highlighted row can honour, so
                // the footer never promises an action that degrades to open.
                if supports(.newWorktree) { keyHint("⌥↩", label: "worktree") }
                if supports(.newTab) { keyHint("⇧↩", label: "new tab") }
                if supports(.revealInFinder) { keyHint("⌘↩", label: "finder") }
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
        .task {
            // The terminal gives up first responder asynchronously when the palette
            // opens; claim the search field just after so it reliably wins keyboard
            // focus (otherwise keystrokes fall through to the terminal).
            try? await Task.sleep(for: .milliseconds(40))
            searchFocused = true
        }
        .onAppear(perform: installMonitor)
        .onDisappear(perform: removeMonitor)
    }

    // A local keyDown monitor is the reliable way to drive a palette: the focused
    // text field would otherwise swallow the arrow keys for cursor movement.
    private func installMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event -> NSEvent? in
            MainActor.assumeIsolated {
                switch event.keyCode {
                case 126: model.paletteMove(-1); return nil          // ↑
                case 125: model.paletteMove(1); return nil           // ↓
                case 36, 76:                                         // return / enter
                    model.paletteActivate(modifiers: PaletteModifiers(event.modifierFlags))
                    return nil
                case 53: model.closeCommandPalette(); return nil     // esc
                case 51:                                             // delete / backspace
                    if !model.paletteQuery.isEmpty { model.paletteQuery.removeLast() }
                    return nil
                default:
                    // Route printable typing straight into the query. The local
                    // monitor always fires, so a character can never be dropped by a
                    // focus race or fall through to the terminal. Modified keys
                    // (⌘V paste, ⌘A, …) pass through to the focused field.
                    let mods = event.modifierFlags.intersection([.command, .control, .option])
                    if mods.isEmpty, let chars = event.characters, !chars.isEmpty,
                       chars.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) {
                        model.paletteQuery += chars
                        return nil
                    }
                    return event
                }
            }
        }
    }

    private func removeMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func resultRow(_ item: CommandPaletteItem) -> some View {
        Button {
            model.jump(to: item)
        } label: {
            HStack(spacing: 11) {
                if item.kind == .repo {
                    // A repo has no agent state to report — it is not running
                    // yet — so the dot's slot carries the "not open" mark.
                    Image(systemName: "folder")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 8)
                } else {
                    StatusDot(status: item.status)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(item.subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer()
                Text(item.badge)
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .tracking(0.5)
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 47)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        model.paletteSelectedID == item.id
                            ? Theme.accent.opacity(0.17)
                            : Color.clear
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { model.paletteSelectedID = item.id }
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
                        .fill(Theme.interactionWash(opacity: 0.07))
                )
            Text(label)
        }
        .font(.system(size: 9.5))
        .foregroundStyle(Theme.textTertiary)
    }
}
