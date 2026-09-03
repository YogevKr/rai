import Foundation
import RaiCore
import SwiftUI

struct TranscriptSearchMatchRanges: Equatable {
    let text: [NSRange]
    let toolName: [NSRange]
    let toolSummary: [NSRange]

    var isMatch: Bool {
        !text.isEmpty || !toolName.isEmpty || !toolSummary.isEmpty
    }
}

@MainActor
final class TranscriptHistoryViewModel: ObservableObject {
    @Published var query = "" {
        didSet { rebuildSearchCache() }
    }
    @Published private(set) var turns: [TranscriptTurn] = []
    @Published private(set) var sessionID = ""
    @Published private(set) var hasMore = false
    @Published private(set) var sinceLastSeen: Int?
    @Published private(set) var state: TranscriptHistoryState = .notFound
    private(set) var searchMatches: [Int: TranscriptSearchMatchRanges] = [:]
    private(set) var searchCacheBuildCount = 0

    init(page: TranscriptHistoryPage? = nil) {
        if let page { apply(page) }
    }

    var filteredTurns: [TranscriptTurn] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return turns }
        return turns.filter { searchMatches[$0.id]?.isMatch == true }
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
        if !sessionID.isEmpty, sessionID != page.agentSessionID || !isOlderPage {
            turns = []
            sinceLastSeen = nil
        }
        sessionID = page.agentSessionID
        state = page.state
        var byIndex = Dictionary(uniqueKeysWithValues: turns.map { ($0.index, $0) })
        for turn in page.turns { byIndex[turn.index] = turn }
        turns = byIndex.values.sorted { $0.index < $1.index }
        hasMore = page.hasMore
        sinceLastSeen = isOlderPage
            ? sinceLastSeen
            : page.sinceLastSeen
        rebuildSearchCache()
    }

    func clear() {
        turns = []
        sessionID = ""
        hasMore = false
        sinceLastSeen = nil
        state = .notFound
        rebuildSearchCache()
    }

    func matchRanges(for turnID: Int) -> TranscriptSearchMatchRanges? {
        searchMatches[turnID]
    }

    private func rebuildSearchCache() {
        searchCacheBuildCount += 1
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            searchMatches = [:]
            return
        }
        searchMatches = Dictionary(uniqueKeysWithValues: turns.map { turn in
            (turn.id, TranscriptSearchMatchRanges(
                text: Self.matchRanges(in: turn.text, term: term),
                toolName: Self.matchRanges(in: turn.tool?.name ?? "", term: term),
                toolSummary: Self.matchRanges(in: turn.tool?.summary ?? "", term: term)
            ))
        })
    }

    private static func matchRanges(in text: String, term: String) -> [NSRange] {
        let source = text as NSString
        var searchRange = NSRange(location: 0, length: source.length)
        var matches: [NSRange] = []
        while searchRange.length > 0 {
            let match = source.range(
                of: term,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchRange,
                locale: .current
            )
            guard match.location != NSNotFound else { break }
            matches.append(match)
            let next = NSMaxRange(match)
            searchRange = NSRange(location: next, length: source.length - next)
        }
        return matches
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
        let displayedTurns = model.filteredTurns
        ScrollViewReader { proxy in
            Group {
                if needsClaudeHook || model.turns.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if let before = model.olderBeforeTurnIndex {
                                Button("Load older") {
                                    connection.requestHistory(
                                        paneID: pane.paneID,
                                        sessionID: paneSessionID,
                                        beforeTurnIndex: before
                                    )
                                }
                                .frame(maxWidth: .infinity)
                            }

                            ForEach(Array(displayedTurns.enumerated()), id: \.element.id) {
                                position, turn in
                                if showsAwayDivider(
                                    before: turn,
                                    at: position,
                                    displayedTurns: displayedTurns
                                ) {
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
                    connection.requestHistory(paneID: pane.paneID, sessionID: paneSessionID)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh conversation history")
            }
        }
        .searchable(text: $model.query, prompt: "Find in conversation")
        .onAppear {
            if let page = connection.historyPages[pane.paneID] { model.apply(page) }
            connection.requestHistory(paneID: pane.paneID, sessionID: paneSessionID)
        }
        .onReceive(connection.$historyPages) { pages in
            if let page = pages[pane.paneID] {
                model.apply(page)
            } else {
                model.clear()
            }
        }
        .onChange(of: connection.status.isConnected) { _, connected in
            if connected {
                connection.requestHistory(paneID: pane.paneID, sessionID: paneSessionID)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            if connection.historyErrors[pane.paneID] != nil {
                Label("History unavailable", systemImage: "exclamationmark.triangle")
            } else if needsClaudeHook
                || model.state == .hookRequired || model.state == .ambiguous {
                Label("History needs the Claude hook", systemImage: "link.badge.plus")
            } else {
                Label("No transcript found", systemImage: "clock")
            }
        } description: {
            if let error = connection.historyErrors[pane.paneID] {
                Text(error)
            } else if needsClaudeHook
                || model.state == .hookRequired || model.state == .ambiguous {
                Text("Enable the Claude hook in Settings → Integrations.")
            } else if pane.agent == "claude" {
                Text("Claude has not reported a transcript yet.")
            } else {
                Text("History is available for local Claude panes.")
            }
        }
    }

    private var paneSessionID: String {
        needsClaudeHook ? "" : pane.beacon?.sessionID ?? ""
    }

    private var needsClaudeHook: Bool {
        guard let beacon = pane.beacon else { return true }
        return beacon.sessionID.isEmpty || beacon.transcriptPath.isEmpty
    }

    private func showsAwayDivider(
        before turn: TranscriptTurn,
        at position: Int,
        displayedTurns: [TranscriptTurn]
    ) -> Bool {
        guard let marker = model.sinceLastSeen, turn.index > marker else { return false }
        guard position > 0 else { return true }
        return displayedTurns[position - 1].index <= marker
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
