import RaiCore
import SwiftUI

@MainActor
final class TranscriptHistoryViewModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var turns: [TranscriptTurn] = []
    @Published private(set) var sessionID = ""
    @Published private(set) var hasMore = false
    @Published private(set) var sinceLastSeen: Int?

    init(page: TranscriptHistoryPage? = nil) {
        if let page { apply(page) }
    }

    var filteredTurns: [TranscriptTurn] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return turns }
        return turns.filter { turn in
            turn.text.localizedCaseInsensitiveContains(term)
                || turn.tool?.name.localizedCaseInsensitiveContains(term) == true
                || turn.tool?.summary.localizedCaseInsensitiveContains(term) == true
        }
    }

    var olderBeforeTurnIndex: Int? {
        hasMore ? turns.first?.index : nil
    }

    var lastPromptIndex: Int? {
        turns.last(where: { $0.role == .user })?.index
    }

    func apply(_ page: TranscriptHistoryPage) {
        let isOlderPage = page.turns.last.map { latest in
            turns.first.map { latest.index < $0.index } ?? false
        } ?? false
        if !sessionID.isEmpty, sessionID != page.sessionID || !isOlderPage {
            turns = []
            sinceLastSeen = nil
        }
        sessionID = page.sessionID
        var byIndex = Dictionary(uniqueKeysWithValues: turns.map { ($0.index, $0) })
        for turn in page.turns { byIndex[turn.index] = turn }
        turns = byIndex.values.sorted { $0.index < $1.index }
        hasMore = page.hasMore
        sinceLastSeen = isOlderPage
            ? sinceLastSeen
            : page.sinceLastSeen
    }

    func clear() {
        turns = []
        sessionID = ""
        hasMore = false
        sinceLastSeen = nil
    }
}

struct TranscriptHistoryView: View {
    let pane: Pane
    @ObservedObject var connection: BridgeConnection
    @StateObject private var model: TranscriptHistoryViewModel
    @State private var scrolledToNewest = false

    init(pane: Pane, connection: BridgeConnection) {
        self.pane = pane
        self.connection = connection
        _model = StateObject(wrappedValue: TranscriptHistoryViewModel(
            page: connection.historyPages[pane.paneID]
        ))
    }

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if model.turns.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if let before = model.olderBeforeTurnIndex {
                                Button("Load older") {
                                    connection.requestHistory(
                                        paneID: pane.paneID,
                                        beforeTurnIndex: before
                                    )
                                }
                                .frame(maxWidth: .infinity)
                            }

                            ForEach(Array(model.filteredTurns.enumerated()), id: \.element.id) {
                                position, turn in
                                if showsAwayDivider(before: turn, at: position) {
                                    AwayDivider()
                                }
                                TranscriptTurnCard(turn: turn)
                                    .id(turn.index)
                            }
                        }
                        .padding()
                    }
                    .defaultScrollAnchor(.bottom)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let index = model.lastPromptIndex, !model.turns.isEmpty {
                    Button {
                        model.query = ""
                        DispatchQueue.main.async {
                            withAnimation { proxy.scrollTo(index, anchor: .center) }
                        }
                    } label: {
                        Label("Jump to my last prompt", systemImage: "arrow.down.to.line")
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
                }
            }
            .onChange(of: model.turns.last?.index) { _, newest in
                guard !scrolledToNewest, let newest else { return }
                scrolledToNewest = true
                DispatchQueue.main.async { proxy.scrollTo(newest, anchor: .bottom) }
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    connection.requestHistory(paneID: pane.paneID)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh conversation history")
            }
        }
        .searchable(text: $model.query, prompt: "Find in conversation")
        .onAppear {
            if let page = connection.historyPages[pane.paneID] { model.apply(page) }
            connection.requestHistory(paneID: pane.paneID)
        }
        .onReceive(connection.$historyPages) { pages in
            if let page = pages[pane.paneID] {
                model.apply(page)
            } else {
                model.clear()
            }
        }
        .onChange(of: connection.status.isConnected) { _, connected in
            if connected { connection.requestHistory(paneID: pane.paneID) }
        }
        .preferredColorScheme(.dark)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No transcript found", systemImage: "clock")
        } description: {
            if pane.agent == "claude" {
                Text("Claude has not reported a transcript yet.")
            } else {
                Text("History is available for local Claude panes.")
            }
        }
    }

    private func showsAwayDivider(before turn: TranscriptTurn, at position: Int) -> Bool {
        guard let marker = model.sinceLastSeen, turn.index > marker else { return false }
        guard position > 0 else { return true }
        return model.filteredTurns[position - 1].index <= marker
    }
}

private struct AwayDivider: View {
    var body: some View {
        HStack {
            Rectangle().frame(height: 1)
            Text("While you were away")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Night.amber)
                .fixedSize()
            Rectangle().frame(height: 1)
        }
        .foregroundStyle(Night.hotEdge)
        .accessibilityElement(children: .combine)
    }
}

private struct TranscriptTurnCard: View {
    let turn: TranscriptTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(roleLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(roleColor)
                Spacer()
                if let timestamp = turn.timestamp {
                    Text(timestamp, style: .time)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Night.dim)
                }
            }
            if let tool = turn.tool {
                HStack(spacing: 6) {
                    Image(systemName: "hammer.fill")
                    Text(tool.name).fontWeight(.semibold)
                    if !tool.summary.isEmpty {
                        Text(tool.summary).lineLimit(1)
                    }
                }
                .font(.caption.monospaced())
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Night.ground, in: Capsule())
            }
            if !turn.text.isEmpty {
                Text(turn.text)
                    .font(turn.role == .tool ? .callout.monospaced() : .body)
                    .textSelection(.enabled)
            }
            if turn.truncated {
                Text("Text was shortened")
                    .font(.caption)
                    .foregroundStyle(Night.dim)
            }
        }
        .foregroundStyle(Night.text)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardColor, in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .leading) {
            if turn.role == .user {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Night.repoBlue)
                    .frame(width: 3)
                    .padding(.vertical, 8)
            }
        }
    }

    private var roleLabel: String {
        switch turn.role {
        case .user: "You"
        case .assistant: turn.tool == nil ? "Assistant" : "Tool call"
        case .tool: "Tool result"
        }
    }

    private var roleColor: Color {
        switch turn.role {
        case .user: Night.repoBlue
        case .assistant: Night.green
        case .tool: Night.amber
        }
    }

    private var cardColor: Color {
        turn.role == .user ? Night.repoBlue.opacity(0.13) : Night.row
    }
}
