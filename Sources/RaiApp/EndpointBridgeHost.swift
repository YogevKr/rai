import Combine
import Foundation
import RaiCore

/// One authenticated bridge client owns one view. Delivery coalesces behind one socket write.
@MainActor
final class EndpointBridgeHost {
    let identity: EndpointViewIdentity
    private let model: EndpointWindowModel
    private let emit: (EndpointBridgeState, @escaping () -> Void) -> Void
    private var observation: AnyCancellable?
    private var delivery: Task<Void, Never>?
    private var sending = false
    private var deliveredImages: Set<EndpointGraphicsKey> = []
    private var dirty = false
    private var stopped = false
    private var sequence: UInt64 = 0
    private var failure: String?
    private var rejectedPlugin: EndpointPluginResult?

    init(identity: EndpointViewIdentity, socketPath: String, remoteContext: RemoteConnection.Context? = nil,
         model suppliedModel: EndpointWindowModel? = nil,
         emit: @escaping (EndpointBridgeState, @escaping () -> Void) -> Void) {
        self.identity = identity
        model = suppliedModel ?? EndpointWindowModel(socketPath: socketPath, machineEndpoint: identity.machineEndpoint, machineConnectionID: identity.connectionID, remoteContext: remoteContext)
        self.emit = emit
        observation = model.objectWillChange.sink { [weak self] _ in self?.scheduleState() }
    }

    func ownsRetainedConnection(_ identity: EndpointViewIdentity) -> Bool {
        !stopped && failure == nil && self.identity == identity && model.retainsHostConnection
    }

    func stop() {
        stopped = true
        observation = nil
        delivery?.cancel()
        delivery = nil
        model.stop()
    }

    func invalidate() {
        model.stop()
        failure = "The host connection changed. Open this view again."
        scheduleState()
    }

    func handle(_ request: EndpointBridgeRequest) {
        guard !stopped, failure == nil else { return }
        do {
            guard request.identity == identity, sequence < UInt64.max, request.sequence == sequence + 1 else {
                throw HerdrEndpointError.staleIdentity
            }
            if case .open = request.operation {
                guard sequence == 0, request.bootID == nil else { throw HerdrEndpointError.staleIdentity }
            } else if case .close = request.operation {
                // Closing releases only this identity. It remains valid after a server disconnect.
            } else {
                guard let snapshot = model.snapshot, request.bootID == snapshot.bootID else { throw HerdrEndpointError.staleIdentity }
            }
            sequence = request.sequence
            try apply(request)
        } catch {
            failure = error.localizedDescription
            model.stop()
        }
        scheduleState()
    }

    private func apply(_ request: EndpointBridgeRequest) throws {
        switch request.operation {
        case .open(let columns, let rows):
            try resize(columns: columns, rows: rows)
            model.start()
        case .close: stop()
        case .resize(let columns, let rows): try resize(columns: columns, rows: rows)
        case .input(let paneID, let input):
            guard model.acceptsInput, model.surface?.popup == nil,
                  let revision = request.projectionRevision else { throw HerdrEndpointError.busy }
            model.send(try input.input(), paneID: paneID, bootID: request.bootID, projectionRevision: revision)
        case .popupInput(let terminalID, let input):
            guard model.acceptsInput, model.surface?.popup?.terminalID == terminalID,
                  let revision = request.projectionRevision else { throw HerdrEndpointError.staleIdentity }
            model.send(try input.input(), bootID: request.bootID, projectionRevision: revision)
        case .terminalAction(let action):
            guard model.performTerminalAction(action) else { throw HerdrEndpointError.staleIdentity }
        case .layout(let layout):
            guard layout.owningViewID == identity.viewID, model.performLayout(layout, owningViewID: identity.viewID) else {
                throw HerdrEndpointError.staleIdentity
            }
        case .launchAgent(let launch):
            guard model.launchAgent(launch, owningViewID: identity.viewID) else { throw HerdrEndpointError.staleIdentity }
        case .worktree(let worktree):
            guard model.performWorktree(worktree) else { throw HerdrEndpointError.staleIdentity }
        case .plugin(let plugin):
            guard plugin.bootID == model.snapshot?.bootID else { throw HerdrEndpointError.staleIdentity }
            if model.performPlugin(plugin) { rejectedPlugin = nil }
            else {
                rejectedPlugin = .init(requestID: plugin.id,
                    error: (model.busy ? HerdrEndpointError.busy : HerdrEndpointError.staleIdentity).localizedDescription)
            }
        case .command(let command):
            guard !model.busy, model.snapshot != nil else { throw HerdrEndpointError.busy }
            if case .invoke(let invocation) = command {
                guard model.invoke(invocation) else { throw HerdrEndpointError.staleIdentity }
            } else if case .scroll(let paneID, let offset) = command {
                guard model.surface?.panes.contains(where: { $0.paneID == paneID }) == true else {
                    throw HerdrEndpointError.staleIdentity
                }
                model.scroll(paneID: paneID, offset: offset)
            } else {
                let rpc = command.rpc
                model.perform(rpc.method, params: rpc.params)
            }
        }
    }

    private func resize(columns: Int, rows: Int) throws {
        guard (1...240).contains(columns), (1...120).contains(rows) else { throw HerdrEndpointError.limitExceeded }
        model.resize(columns: columns, rows: rows)
    }

    private func scheduleState() {
        guard !stopped else { return }
        dirty = true
        guard !sending, delivery == nil else { return }
        delivery = Task { [weak self] in
            await Task.yield() // ObservableObject publishes before it changes the stored value.
            guard let self, !Task.isCancelled, !stopped else { return }
            delivery = nil
            dirty = false
            sending = true
            var surface = model.surface
            if let scene = surface?.graphics {
                surface?.graphics = scene.excludingAssets(deliveredImages)
                deliveredImages = Set(scene.assets.map(\.key))
            }
            var outgoingState = EndpointBridgeState(identity: identity, sequence: sequence, snapshot: model.snapshot,
                surface: surface, methods: model.methods.sorted(), busy: model.busy, error: failure ?? model.error, worktreeResult: model.worktreeResult)
            outgoingState.agentLaunchResult = model.agentLaunchResult
            outgoingState.pluginResult = rejectedPlugin ?? model.pluginResult
            outgoingState.notifications = model.notifications
            outgoingState.windowTitle = model.windowTitle
            outgoingState.terminalResult = model.terminalResult
            outgoingState.layoutResult = model.layoutResult
            outgoingState.graphicsPolicyWarning = model.graphicsPolicyWarning
            outgoingState.retainsHostConnection = model.retainsHostConnection
            emit(outgoingState) { [weak self] in
                    guard let self else { return }
                    sending = false
                    if dirty { scheduleState() }
                }
        }
    }
}
