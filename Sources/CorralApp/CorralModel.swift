import CorralCore
import Foundation
import SwiftUI

struct TerminalFrame: Equatable {
    let paneID: String
    let text: String
    let revision: UInt64
    let sequence: UInt64
}

@MainActor
final class CorralModel: ObservableObject {
    enum ConnectionState: Equatable {
        case connecting
        case connected(version: String, protocolVersion: Int)
        case disconnected(String)
    }

    @Published private(set) var snapshot: SessionSnapshot?
    @Published private(set) var terminalFrame: TerminalFrame?
    @Published private(set) var connectionState: ConnectionState = .connecting
    @Published var selectedPaneID: String?

    let client: HerdrClient

    private var started = false
    private var eventTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var pendingEvents: [HerdrEvent] = []
    private var frameSequence: UInt64 = 0
    private var readInFlight = false

    init(client: HerdrClient = HerdrClient()) {
        self.client = client
    }

    deinit {
        eventTask?.cancel()
        pollTask?.cancel()
        flushTask?.cancel()
    }

    var selectedPane: Pane? {
        snapshot?.panes.first { $0.paneID == selectedPaneID }
    }

    var selectedTabID: String? {
        selectedPane?.tabID
    }

    func start() {
        guard !started else { return }
        started = true
        connectionState = .connecting

        Task {
            await refreshSnapshot(keepSelection: false)
            startEventLoop()
            startOutputFallback()
        }
    }

    func select(tab: HerdrTab) {
        guard let snapshot else { return }
        let candidates = snapshot.panes.filter { $0.tabID == tab.tabID }
        guard let pane = candidates.first(where: \.focused) ?? candidates.first else { return }
        select(paneID: pane.paneID, focusInHerdr: true)
    }

    func select(paneID: String, focusInHerdr: Bool) {
        guard selectedPaneID != paneID || terminalFrame == nil else { return }
        selectedPaneID = paneID
        terminalFrame = nil
        Task {
            if focusInHerdr {
                do {
                    try await client.focusPane(paneID)
                } catch {
                    connectionState = .disconnected(error.localizedDescription)
                }
            }
            await refreshPane(force: true)
        }
    }

    func refreshNow() {
        Task {
            await refreshSnapshot(keepSelection: true)
            await refreshPane(force: true)
        }
    }

    private func startEventLoop() {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let paneIDs = snapshot?.panes.map(\.paneID) ?? []
                    for try await event in client.events(paneIDs: paneIDs) {
                        queue(event)
                    }
                } catch {
                    if !Task.isCancelled {
                        connectionState = .disconnected(error.localizedDescription)
                    }
                }
                guard !Task.isCancelled else { break }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func startOutputFallback() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(700))
                guard let self, self.selectedPaneID != nil else { continue }
                await self.refreshPane(force: false)
            }
        }
    }

    private func queue(_ event: HerdrEvent) {
        pendingEvents.append(event)
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(90))
            guard let self, !Task.isCancelled else { return }
            await self.flushEvents()
        }
    }

    private func flushEvents() async {
        let events = pendingEvents
        pendingEvents.removeAll(keepingCapacity: true)
        flushTask = nil
        guard !events.isEmpty else { return }

        let selected = selectedPaneID
        let outputChanged = events.contains {
            $0.name == "pane.output_changed" && $0.paneID == selected
        }
        let treeChanged = events.contains { $0.name != "pane.output_changed" }

        if treeChanged {
            await refreshSnapshot(keepSelection: true)
        }
        if outputChanged || treeChanged {
            await refreshPane(force: outputChanged)
        }
    }

    private func refreshSnapshot(keepSelection: Bool) async {
        do {
            let newSnapshot = try await client.snapshot()
            snapshot = newSnapshot
            connectionState = .connected(
                version: newSnapshot.version,
                protocolVersion: newSnapshot.protocol
            )

            if keepSelection,
               let selectedPaneID,
               newSnapshot.panes.contains(where: { $0.paneID == selectedPaneID }) {
                return
            }

            let preferred = newSnapshot.focusedPaneID
                ?? newSnapshot.panes.first(where: \.focused)?.paneID
                ?? newSnapshot.panes.first?.paneID
            if preferred != selectedPaneID {
                selectedPaneID = preferred
                terminalFrame = nil
            }
            await refreshPane(force: true)
        } catch {
            connectionState = .disconnected(error.localizedDescription)
        }
    }

    private func refreshPane(force: Bool) async {
        guard let paneID = selectedPaneID, !readInFlight else { return }
        readInFlight = true
        defer { readInFlight = false }

        do {
            let read = try await client.readPane(paneID: paneID)
            guard paneID == selectedPaneID else { return }
            if !force,
               let terminalFrame,
               terminalFrame.paneID == paneID,
               terminalFrame.revision == read.revision,
               terminalFrame.text == read.text {
                return
            }
            frameSequence &+= 1
            terminalFrame = TerminalFrame(
                paneID: paneID,
                text: read.text,
                revision: read.revision,
                sequence: frameSequence
            )
            if case .disconnected = connectionState, let snapshot {
                connectionState = .connected(
                    version: snapshot.version,
                    protocolVersion: snapshot.protocol
                )
            }
        } catch {
            connectionState = .disconnected(error.localizedDescription)
        }
    }
}
