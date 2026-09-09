import Combine
import Foundation
import RaiCore

@MainActor
final class EndpointPhoneModel: ObservableObject {
    @Published private(set) var state: EndpointBridgeState?
    @Published private(set) var error: String?
    @Published private(set) var identity: EndpointViewIdentity?
    var retainsHostConnection: Bool { identity != nil && state?.identity == identity && state?.retainsHostConnection == true }
    @Published private var commandSequence: UInt64 = 0
    private var sequence: UInt64 = 0
    private var failed = false
    private var closing = false
    @Published private(set) var scrollActivity: [String: UInt64] = [:]
    private var pendingScroll: (paneID: String, offset: UInt64)?
    private var scrolling = false
    private var graphics = EndpointGraphicsCache()
    private var sender: ((EndpointBridgeRequest) async throws -> Void)?
    private var outbound: Task<Void, Never>?
    private var queued = 0
    private var queuedBytes = 0
    private var pendingText: EndpointTextBatch<EndpointBridgeRequest>?
    private var desiredSize: (columns: Int, rows: Int)?
    private var sentSize: (columns: Int, rows: Int)?
    private var pendingPlugin: (requestID: String, pluginID: UUID)?

    var busy: Bool { error == nil && (state == nil || state?.busy == true || commandSequence > (state?.sequence ?? 0)) }
    var acceptsInput: Bool {
        guard error == nil, !busy, let snapshot = state?.snapshot, let surface = state?.surface else { return false }
        return snapshot.bootID == surface.bootID && surface.projectionRevision <= snapshot.revision
            && surface.panes.first(where: \.focused)?.paneID == snapshot.focusedPaneID
    }

    func open(connectionID: String, machineEndpoint: MachineEndpoint? = nil, sender: @escaping (EndpointBridgeRequest) async throws -> Void) {
        disconnect()
        self.sender = sender
        identity = EndpointViewIdentity(connectionID: connectionID, machineEndpoint: machineEndpoint)
        error = nil
        let size = desiredSize ?? (columns: 80, rows: 32)
        sentSize = size
        enqueue(.open(columns: size.columns, rows: size.rows), blocksInput: true)
    }

    func receive(_ received: EndpointBridgeState) {
        var next = received
        guard !failed, next.identity == identity, next.sequence <= sequence,
              next.sequence >= (state?.sequence ?? 0) else { return }
        if let bootID = state?.snapshot?.bootID, let nextBoot = next.snapshot?.bootID, bootID != nextBoot {
            failed = true
            error = "The server restarted. Open the workspace view again."
            return
        }
        if let scene = next.surface?.graphics { next.surface?.graphics = graphics.resolve(scene) }
        if next.pluginResult?.requestID == pendingPlugin?.pluginID { pendingPlugin = nil }
        state = next
        if let error = next.error { failed = true; self.error = error }
        else if !failed { error = nil }
        sendDesiredSize()
        if !busy { scrolling = false; sendPendingScroll() }
    }

    func receiveError(_ text: String, requestID: String?) {
        guard let identity, requestID?.hasPrefix(identity.viewID.uuidString + ":") == true else { return }
        failed = true
        error = text
        if let pendingPlugin, pendingPlugin.requestID == requestID {
            state?.pluginResult = .init(requestID: pendingPlugin.pluginID, error: text)
            self.pendingPlugin = nil
        }
    }

    @discardableResult
    func performLayout(_ request: EndpointLayoutRequest) -> Bool {
        guard !busy, error == nil, let snapshot = state?.snapshot, request.owningViewID == identity?.viewID,
              (request.action.method == "pane.move" || state?.methods.contains(request.action.method) == true),
              (try? request.validate(in: snapshot)) != nil else { return false }
        enqueue(.layout(request), blocksInput: true)
        return true
    }

    @discardableResult
    func performWorktree(_ request: EndpointWorktreeRequest) -> Bool {
        guard !busy, error == nil, let snapshot = state?.snapshot,
              state?.methods.contains(request.operation.rpc.method) == true,
              (try? request.validate(in: snapshot)) != nil else { return false }
        enqueue(.worktree(request), blocksInput: true)
        return true
    }

    func launchAgent(_ request: EndpointAgentLaunchRequest) -> Bool {
        guard !busy, error == nil, let snapshot = state?.snapshot, request.owningViewID == identity?.viewID,
              (try? request.validate(in: snapshot)) != nil else { return false }
        enqueue(.launchAgent(request), blocksInput: true)
        return true
    }

    func performPlugin(_ request: EndpointPluginRequest) -> Bool {
        let cancelling: Bool
        if case .cancelInstall = request.operation { cancelling = true } else { cancelling = false }
        guard !busy || cancelling, error == nil, state?.snapshot?.bootID == request.bootID else { return false }
        if let method = request.operation.endpointMethod, state?.methods.contains(method) != true { return false }
        if case .openPane(let invocation) = request.operation {
            guard let snapshot = state?.snapshot, (try? invocation.validate(in: snapshot)) != nil else { return false }
        }
        if case .activateLink(let link) = request.operation {
            guard let surface = state?.surface, (try? link.validate(in: surface)) != nil else { return false }
        }
        enqueue(.plugin(request), blocksInput: true)
        return true
    }

    @discardableResult
    func performTerminalAction(_ request: EndpointTextRequest) -> Bool {
        guard !busy, error == nil, let snapshot = state?.snapshot,
              (try? request.validate(snapshot: snapshot, surface: state?.surface)) != nil else { return false }
        if let rpc = request.historyRPC, state?.methods.contains(rpc.method) != true { return false }
        enqueue(.terminalAction(request), blocksInput: true)
        return true
    }

    func command(_ command: EndpointBridgeCommand) {
        guard !busy, error == nil, state?.methods.contains(command.rpc.method) == true else { return }
        enqueue(.command(command), blocksInput: true)
    }

    func invoke(_ invocation: EndpointCommandInvocation) -> Bool {
        guard !busy, error == nil, state?.methods.contains("command.invoke") == true,
              let snapshot = state?.snapshot, (try? invocation.validate(in: snapshot)) != nil else { return false }
        command(.invoke(invocation))
        return true
    }

    func input(_ input: EndpointBridgeInput) {
        guard acceptsInput, let paneID = state?.snapshot?.focusedPaneID else { return }
        if let terminalID = state?.surface?.popup?.terminalID {
            enqueue(.popupInput(terminalID: terminalID, input: input))
        } else { enqueue(.input(paneID: paneID, input: input)) }
    }

    func scroll(paneID: String, offset: UInt64) {
        guard state?.surface?.popup == nil, error == nil, !busy || scrolling, state?.methods.contains("pane.scroll") == true,
              let pane = state?.surface?.panes.first(where: { $0.paneID == paneID }), let metrics = pane.scroll else { return }
        pendingScroll = (paneID, min(offset, metrics.maximum, EndpointScroll.maximumOffset))
        scrollActivity[paneID, default: 0] &+= 1
        sendPendingScroll()
    }

    private func sendPendingScroll() {
        guard !busy, error == nil, let pending = pendingScroll else { return }
        pendingScroll = nil
        scrolling = true
        enqueue(.command(.scroll(paneID: pending.paneID, offset: pending.offset)), blocksInput: true)
    }

    func scrollPage(_ direction: Int) {
        guard let pane = state?.surface?.panes.first(where: \.focused), let metrics = pane.scroll else { return }
        let lines = direction * Int(min(metrics.rows, 120))
        scroll(paneID: pane.paneID, offset: EndpointScroll.offset(from: metrics.offset, lines: lines, maximum: metrics.maximum))
    }

    func resize(columns: Int, rows: Int) {
        desiredSize = (max(1, min(columns, 240)), max(1, min(rows, 120)))
        sendDesiredSize()
    }

    private func sendDesiredSize() {
        guard state?.snapshot != nil, error == nil, let desiredSize,
              sentSize?.columns != desiredSize.columns || sentSize?.rows != desiredSize.rows else { return }
        sentSize = desiredSize
        enqueue(.resize(columns: desiredSize.columns, rows: desiredSize.rows))
    }

    func close() {
        guard identity != nil, !closing else { return }
        closing = true
        enqueue(.close)
        // The queued close owns this view until it completes. UI input stops immediately.
        failed = true
        error = "Workspace view closed."
    }

    func disconnect() {
        identity = nil
        state = nil
        sentSize = nil
        pendingScroll = nil
        scrolling = false
        scrollActivity = [:]
        pendingPlugin = nil
        graphics = EndpointGraphicsCache()
        sequence = 0
        failed = false
        closing = false
        commandSequence = 0
        queued = 0
        queuedBytes = 0
        pendingText = nil
        outbound?.cancel()
        outbound = nil
        sender = nil
        error = "Open the workspace view to connect."
    }

    private func committedText(in operation: EndpointBridgeOperation) -> (text: String, route: EndpointBridgeOperation)? {
        switch operation {
        case .input(let paneID, .text(let text)): return (text, .input(paneID: paneID, input: .text("")))
        case .popupInput(let terminalID, .text(let text)): return (text, .popupInput(terminalID: terminalID, input: .text("")))
        default: return nil
        }
    }

    private func enqueue(_ operation: EndpointBridgeOperation, blocksInput: Bool = false) {
        guard let identity, let sender, sequence < UInt64.max else { return }
        let size: Int
        switch operation {
        case .input(_, let input), .popupInput(_, let input): size = (try? input.input().byteCount) ?? 1_000_001
        default: size = 128
        }
        let textPart = committedText(in: operation)
        let context = textPart.map {
            EndpointBridgeRequest(identity: identity, sequence: 0, bootID: state?.snapshot?.bootID,
                projectionRevision: state?.snapshot?.revision, operation: $0.route)
        }
        if let textPart, let context, textPart.text.utf8.count <= 1_000_000 - queuedBytes,
           pendingText?.append(textPart.text, context: context) == true {
            queuedBytes += textPart.text.utf8.count
            return
        }
        guard queued < 64, size <= 1_000_000 - queuedBytes else {
            failed = true
            error = "The input queue is full. Open a new workspace view."
            return
        }
        sequence += 1
        if blocksInput { commandSequence = sequence }
        let request = EndpointBridgeRequest(identity: identity, sequence: sequence, bootID: state?.snapshot?.bootID,
            projectionRevision: state?.snapshot?.revision, operation: operation)
        if case .plugin(let plugin) = operation { pendingPlugin = (request.requestID, plugin.id) }
        let batch: EndpointTextBatch<EndpointBridgeRequest>?
        if let textPart, let context { batch = EndpointTextBatch(context: context, text: textPart.text) }
        else { batch = nil }
        pendingText = batch
        let previous = outbound
        queued += 1
        queuedBytes += size
        outbound = Task { [weak self] in
            await previous?.value
            guard let self, self.identity == identity, !Task.isCancelled else { return }
            defer { if self.identity == identity { queued -= 1; queuedBytes -= batch?.byteCount ?? size } }
            if failed, operation != .close { return }
            if pendingText === batch { pendingText = nil }
            var outgoing = request
            if let batch {
                let text = batch.seal()
                let operation: EndpointBridgeOperation
                switch request.operation {
                case .input(let paneID, _): operation = .input(paneID: paneID, input: .text(text))
                case .popupInput(let terminalID, _): operation = .popupInput(terminalID: terminalID, input: .text(text))
                default: operation = request.operation
                }
                outgoing = EndpointBridgeRequest(identity: request.identity, sequence: request.sequence,
                    bootID: request.bootID, projectionRevision: request.projectionRevision, operation: operation)
            }
            do { try await sender(outgoing) }
            catch { if self.identity == identity { self.failed = true; self.error = error.localizedDescription } }
        }
    }
}
