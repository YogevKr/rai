import AppKit
import Foundation
import RaiCore

enum MicroControllerIntent: Equatable {
    case selectSlot(Int)
    case focusPane(String)
    case stepSelection(Int)
    case openCommandPalette
    case wisprFlow(Bool)
    case unboundCommand(id: String, state: MicroPressState)
}

enum MicroControllerDecisions {
    static func assignments(from panes: [Pane]) -> [MicroSlotAssignment] {
        panes.sorted {
            if $0.revision != $1.revision { return $0.revision > $1.revision }
            return $0.paneID < $1.paneID
        }.map {
            MicroSlotAssignment(paneID: $0.paneID, status: $0.agentStatus)
        }
    }

    static func statuses(from slots: [MicroSlotAssignment?]) -> [AgentStatus?] {
        slots.map { $0?.status }
    }

    static func nextPaneID(
        in slots: [MicroSlotAssignment?],
        selectedPaneID: String?,
        step: Int
    ) -> String? {
        let paneIDs = slots.compactMap { $0?.paneID }
        guard !paneIDs.isEmpty, step != 0 else { return nil }
        guard let selectedPaneID,
              let current = paneIDs.firstIndex(of: selectedPaneID) else {
            return step > 0 ? paneIDs.first : paneIDs.last
        }
        let offset = step > 0 ? 1 : -1
        return paneIDs[(current + offset + paneIDs.count) % paneIDs.count]
    }

    static func intent(for event: MicroInputEvent) -> MicroControllerIntent? {
        switch event {
        case .agentKey(let index, .press):
            .selectSlot(index)
        case .agentKey(_, .release):
            nil
        case .joystick(let direction, .press):
            .focusPane(direction.rawValue.prefix(1).description)
        case .joystick(_, .release):
            nil
        case .encoder(.clockwise):
            .stepSelection(1)
        case .encoder(.counterclockwise):
            .stepSelection(-1)
        case .encoder(.press):
            .openCommandPalette
        case .encoder(.release):
            nil
        case .commandKey("ACT10", let state):
            .wisprFlow(state == .press)
        case .commandKey("ACT11", _):
            nil
        case .commandKey(let id, let state):
            .unboundCommand(id: id, state: state)
        case .joystickSample, .deviceResponse, .debugLog, .unknown:
            nil
        }
    }
}

/// Optional Codex Micro integration. The documented default is disabled; set
/// `codexMicroEnabled` in UserDefaults to opt in.
@MainActor
final class MicroController {
    static let enabledDefaultsKey = "codexMicroEnabled"
    static let wisprFlowStartURL = URL(string: "wispr-flow://start-hands-free")!
    static let wisprFlowStopURL = URL(string: "wispr-flow://stop-hands-free")!

    typealias UnboundCommandHandler = (String, MicroPressState) -> Void

    private weak var model: RaiModel?
    private var worker: Worker?
    private var wisprFlowUnavailableLogged = false
    var onUnboundCommand: UnboundCommandHandler?

    init(model: RaiModel) {
        self.model = model
    }

    func start() {
        guard worker == nil else { return }
        let worker = Worker { [weak self] intent, slots in
            Task { @MainActor [weak self] in
                self?.perform(intent, slots: slots)
            }
        }
        self.worker = worker
        worker.start()
    }

    func stop() {
        worker?.stop()
        worker = nil
    }

    func update(snapshot: SessionSnapshot) {
        worker?.update(
            assignments: MicroControllerDecisions.assignments(from: snapshot.panes),
            selectedPaneID: model?.selectedPaneID,
            onlyNeedsYou: model?.onlyNeedsYou ?? false
        )
    }

    private func perform(
        _ intent: MicroControllerIntent,
        slots: [MicroSlotAssignment?]
    ) {
        guard let model else { return }
        switch intent {
        case .selectSlot(let index):
            guard slots.indices.contains(index), let paneID = slots[index]?.paneID else {
                return
            }
            model.select(paneID: paneID, focusInHerdr: true)
        case .focusPane(let direction):
            model.focusPane(direction)
        case .stepSelection(let step):
            guard let paneID = MicroControllerDecisions.nextPaneID(
                in: slots,
                selectedPaneID: model.selectedPaneID,
                step: step
            ) else { return }
            model.select(paneID: paneID, focusInHerdr: true)
        case .openCommandPalette:
            if !model.isCommandPalettePresented {
                model.toggleCommandPalette()
            }
        case .wisprFlow(let starting):
            openWisprFlow(starting: starting)
        case .unboundCommand(let id, let state):
            onUnboundCommand?(id, state)
        }
    }

    private func openWisprFlow(starting: Bool) {
        let workspace = NSWorkspace.shared
        guard workspace.urlForApplication(toOpen: Self.wisprFlowStartURL) != nil else {
            if !wisprFlowUnavailableLogged {
                NSLog("rai: no application handles the wispr-flow URL scheme")
                wisprFlowUnavailableLogged = true
            }
            return
        }
        // Leave the mic-position key blank/unassigned in Codex Micro's vendor
        // settings; otherwise ChatGPT desktop will act on the same physical key.
        workspace.open(starting ? Self.wisprFlowStartURL : Self.wisprFlowStopURL)
    }
}

private final class Worker: @unchecked Sendable {
    typealias IntentHandler = @Sendable (
        MicroControllerIntent,
        [MicroSlotAssignment?]
    ) -> Void

    private let lock = NSLock()
    private let intentHandler: IntentHandler
    private var runLoop: CFRunLoop?
    private var pendingBlocks: [@Sendable () -> Void] = []
    private var stopped = false

    // Accessed only on the monitoring thread.
    private var transport: IOHIDMicroTransport?
    private var frameDecoder = MicroFrameDecoder()
    private var joystickTracker = MicroKeyMap.MicroJoystickTracker()
    private var slotAssigner = MicroSlotAssigner()
    private var lighting = MicroLighting()
    private var rpcEncoder = MicroRPCEncoder()
    private var slots: [MicroSlotAssignment?] = Array(repeating: nil, count: 6)
    private var connected = false

    init(intentHandler: @escaping IntentHandler) {
        self.intentHandler = intentHandler
    }

    func start() {
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "rai.codex-micro"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func stop() {
        schedule { [weak self] in
            guard let self else { return }
            transport?.close()
            transport = nil
            connected = false
            if let runLoop { CFRunLoopStop(runLoop) }
        }
        lock.withLock { stopped = true }
    }

    func update(
        assignments: [MicroSlotAssignment],
        selectedPaneID: String?,
        onlyNeedsYou: Bool
    ) {
        schedule { [weak self] in
            guard let self else { return }
            slots = slotAssigner.update(
                assignments,
                selectedPaneID: selectedPaneID,
                onlyNeedsYou: onlyNeedsYou
            )
            sendLightingChanges()
        }
    }

    private func run() {
        autoreleasepool {
            let currentRunLoop = CFRunLoopGetCurrent()
            let queued = lock.withLock { () -> [@Sendable () -> Void] in
                guard !stopped else { return [] }
                runLoop = currentRunLoop
                let queued = pendingBlocks
                pendingBlocks.removeAll()
                return queued
            }
            guard !lock.withLock({ stopped }) else { return }

            let transport = IOHIDMicroTransport()
            self.transport = transport
            transport.onReport = { [weak self] report in self?.consume(report) }
            transport.onConnectionChange = { [weak self, weak transport] connected in
                self?.connectionChanged(connected)
                let identity = transport?.currentDeviceIdentity
                Task { @MainActor in
                    if connected {
                        MicroStatusCenter.shared.deviceAttached(identity: identity)
                    } else {
                        MicroStatusCenter.shared.deviceDetached()
                    }
                }
            }
            do {
                try transport.openMonitoring()
            } catch {
                let message = error.localizedDescription
                NSLog("rai: Codex Micro monitoring failed: \(message)")
                Task { @MainActor in MicroStatusCenter.shared.recordError(message) }
                return
            }
            queued.forEach { $0() }
            CFRunLoopRun()
            transport.close()
        }
    }

    private func schedule(_ block: @escaping @Sendable () -> Void) {
        let target = lock.withLock { () -> CFRunLoop? in
            guard !stopped else { return nil }
            guard let runLoop else {
                pendingBlocks.append(block)
                return nil
            }
            return runLoop
        }
        guard let target else { return }
        CFRunLoopPerformBlock(target, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(target)
    }

    private func connectionChanged(_ isConnected: Bool) {
        connected = isConnected
        guard isConnected else { return }
        lighting = MicroLighting()
        sendLightingChanges()
    }

    private func sendLightingChanges() {
        guard connected else { return }
        let changes = lighting.changes(
            for: MicroControllerDecisions.statuses(from: slots)
        )
        guard !changes.isEmpty, let transport else { return }
        do {
            let request = try rpcEncoder.request(
                method: "v.oai.thstatus",
                params: changes
            )
            for report in try MicroFraming.encode(request.payload) {
                try transport.send(report: report)
            }
        } catch {
            let message = error.localizedDescription
            NSLog("rai: Codex Micro lighting update failed: \(message)")
            Task { @MainActor in MicroStatusCenter.shared.recordError(message) }
        }
    }

    private func consume(_ report: [UInt8]) {
        for output in frameDecoder.consume(report) {
            handle(MicroRPCDecoder.decode(output))
        }
    }

    private func handle(_ event: MicroInputEvent) {
        if case .joystickSample(let angle, let distance) = event {
            for edge in joystickTracker.update(angle: angle, distance: distance) {
                handle(.joystick(direction: edge.direction, state: edge.state))
            }
            return
        }
        // Device replies are not input, but they are the only positive proof the
        // link is alive, so surface them for Settings rather than dropping them.
        if case .deviceResponse(_, _, let error) = event {
            Task { @MainActor in
                if let error {
                    MicroStatusCenter.shared.recordError(
                        "device error \(error.code): \(error.message)"
                    )
                } else {
                    MicroStatusCenter.shared.recordAcknowledgedWrite()
                }
            }
            return
        }
        guard let intent = MicroControllerDecisions.intent(for: event) else { return }
        intentHandler(intent, slots)
    }
}
