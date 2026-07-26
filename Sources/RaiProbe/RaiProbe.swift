import RaiCore
import Foundation

@main
struct RaiProbe {
    static func main() async {
        if CommandLine.arguments.dropFirst().first == "micro" {
            runMicro()
            return
        }
        let client = HerdrClient()
        do {
            try verifyLayoutBuilder()
            let snapshot = try await client.snapshot()
            print(
                "herdr \(snapshot.version) · protocol \(snapshot.protocol) · "
                    + "\(snapshot.workspaces.count) workspaces"
            )
            print("")
            let renderedLayouts = snapshot.layouts.filter {
                PaneLayoutTreeBuilder.build(from: $0) != nil
            }
            guard renderedLayouts.count == snapshot.layouts.count else {
                throw ProbeError.invalidLiveLayout
            }
            print(
                "layouts: \(snapshot.layouts.count) live + nested split self-test passed"
            )
            print("")

            for workspace in snapshot.workspaces.sorted(by: { $0.number < $1.number }) {
                let marker = workspace.workspaceID == snapshot.focusedWorkspaceID ? "→" : " "
                let repo = workspace.worktree.map { " [\($0.repoName)]" } ?? ""
                print(
                    "\(marker) \(statusGlyph(workspace.agentStatus)) \(workspace.label)"
                        + " · \(workspace.tabCount) tabs\(repo)"
                )
                for tab in snapshot.tabs
                    .filter({ $0.workspaceID == workspace.workspaceID })
                    .sorted(by: { $0.number < $1.number }) {
                    let panes = snapshot.panes.filter { $0.tabID == tab.tabID }
                    print(
                        "    \(statusGlyph(tab.agentStatus)) \(tab.label)"
                            + " · \(panes.count) pane\(panes.count == 1 ? "" : "s")"
                    )
                    for pane in panes {
                        let focused = pane.paneID == snapshot.focusedPaneID ? " ← focused" : ""
                        print("        \(pane.paneID) · \(pane.cwd)\(focused)")
                    }
                }
            }

            if let focusedPaneID = snapshot.focusedPaneID {
                let read = try await client.readPane(paneID: focusedPaneID)
                print("")
                print(
                    "focused pane \(focusedPaneID): read \(read.text.utf8.count) ANSI bytes"
                        + " at revision \(read.revision)"
                )
            }

            if CommandLine.arguments.contains("--watch") {
                print("")
                print("reading an initial Herdr event batch…")
                let paneIDs = snapshot.panes.map(\.paneID)
                var eventCount = 0
                for try await event in client.events(paneIDs: paneIDs) {
                    let target = event.paneID ?? event.tabID ?? event.workspaceID ?? ""
                    print("event: \(event.name) \(target)")
                    eventCount += 1
                    if eventCount == 10 {
                        break
                    }
                }
            }

            if let flag = CommandLine.arguments.firstIndex(of: "--send-smoke"),
                CommandLine.arguments.indices.contains(flag + 1) {
                let paneID = CommandLine.arguments[flag + 1]
                let suffix = String(ProcessInfo.processInfo.globallyUniqueString.prefix(8))
                let marker = "RAI_SOCKET_SMOKE_OK_\(suffix)"
                let command = "printf '\(marker)\\n'"
                try await client.sendInput(paneID: paneID, bytes: Array(command.utf8))
                try await client.sendInput(paneID: paneID, bytes: [0x0D])
                var rendered = false
                for _ in 0..<12 {
                    try? await Task.sleep(for: .milliseconds(250))
                    let read = try await client.readPane(
                        paneID: paneID,
                        source: "recent",
                        lines: 30,
                        format: "ansi"
                    )
                    if read.text.contains(marker) {
                        rendered = true
                        break
                    }
                }
                guard rendered else {
                    throw ProbeError.smokeMarkerMissing(paneID)
                }
                print("pane input \(paneID): \(marker)")
            }
        } catch {
            FileHandle.standardError.write(
                Data("rai-probe: \(error.localizedDescription)\n".utf8)
            )
            Foundation.exit(1)
        }
    }

    private static func runMicro() {
        // --watch keeps running across disconnects instead of requiring the pad
        // to be present at launch. Real hardware drops off USB unpredictably, so
        // unattended capture needs this.
        let watch = CommandLine.arguments.contains("--watch")
        let smoke = CommandLine.arguments.contains("--lights-smoke")
        let demo = CommandLine.arguments.contains("--lights-demo")
        let identities = IOHIDMicroTransport.enumerate()
        if identities.isEmpty && !watch {
            FileHandle.standardError.write(
                Data("rai-probe micro: no matching HID interface found\n".utf8)
            )
            Foundation.exit(1)
        }
        for (index, identity) in identities.enumerated() {
            let manufacturer = identity.manufacturer ?? "<unknown>"
            let softCheck = identity.manufacturerMatches ? "match" : "VID/PID fallback"
            let pairs = identity.usagePairs
                .map { String(format: "%04X:%02X", $0.usagePage, $0.usage) }
                .joined(separator: " ")
            print(
                String(
                    format: "VID %04X PID %04X primary-usage-page %04X",
                    identity.vendorID, identity.productID, identity.usagePage
                )
                    + " · collections [\(pairs)]"
                    + " · vendor channel \(identity.hasVendorCollection ? "present" : "MISSING")"
                    + " · reports in/out \(identity.maxInputReportSize)"
                    + "/\(identity.maxOutputReportSize)"
                    + " · manufacturer \(manufacturer) (\(softCheck))"
                    + " · product \(identity.product ?? "<unknown>")"
                    + " · transport \(identity.transport.displayName)"
                    + String(format: " · registry-id 0x%llX", identity.registryEntryID)
                    + (index == 0 ? " · top-ranked node" : "")
            )
        }

        let decoder = ProbeMicroDecoder()
        let transport = IOHIDMicroTransport()
        transport.onReport = { report in
            for event in decoder.consume(report) {
                stamped("micro: \(event)")
            }
        }
        do {
            if watch {
                transport.onDiagnostic = { line in stamped("hid: \(line)") }
                transport.onConnectionChange = { connected in
                    stamped(connected ? "DEVICE ATTACHED" : "DEVICE DROPPED")
                    if !connected { demoTimer?.invalidate(); demoTimer = nil }
                    if connected, let identity = transport.currentDeviceIdentity {
                        stamped(
                            String(
                                format: "selected node registry-id 0x%llX",
                                identity.registryEntryID
                            ) + " · \(identity.transport.displayName)"
                        )
                    }
                    if connected, demo { startLightingDemo(transport) }
                    guard connected, smoke else { return }
                    do {
                        try sendLightingSmoke(transport)
                        stamped("sent lighting smoke frame")
                    } catch {
                        stamped("lighting smoke failed: \(error.localizedDescription)")
                    }
                }
                try transport.openMonitoring()
                stamped("watching for Codex Micro; Control-C to stop")
            } else {
                try transport.open()
                if let identity = transport.currentDeviceIdentity {
                    stamped(
                        String(
                            format: "selected node registry-id 0x%llX",
                            identity.registryEntryID
                        ) + " · \(identity.transport.displayName)"
                    )
                }
                if demo { startLightingDemo(transport) }
                if smoke {
                    try sendLightingSmoke(transport)
                    stamped("sent explicit one-key lighting smoke frame")
                }
                stamped("streaming Codex Micro input; press Control-C to stop")
            }
            RunLoop.current.run()
        } catch {
            FileHandle.standardError.write(
                Data("rai-probe micro: \(error.localizedDescription)\n".utf8)
            )
            Foundation.exit(1)
        }
    }

    /// Timestamped, immediately flushed — unattended runs are read from a log
    /// file while still running, so buffered output is useless.
    private static func stamped(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        FileHandle.standardOutput.write(
            Data("[\(formatter.string(from: Date()))] \(message)\n".utf8)
        )
    }

    /// Paints all six agent keys with the firmware's `rainbow` animation and
    /// syncs the ambient ring to it, then repaints on a timer. Deliberately
    /// unlike anything ChatGPT desktop produces (it only ever shows solid
    /// status colours), so a human can confirm the write path by eye without
    /// ambiguity — and the repaint means ChatGPT cannot quietly erase it.
    private nonisolated(unsafe) static var demoTimer: Timer?

    private static func startLightingDemo(_ transport: IOHIDMicroTransport) {
        // One encoder for the lifetime of the demo. Constructing it inside the
        // repaint closure restarted the sequence, so every request went out as
        // id 0 -- harmless for fire-and-forget lighting, but it would break any
        // request/response correlation.
        // One demo at a time. Re-attaching used to schedule an ADDITIONAL timer
        // without cancelling the previous one; over BLE the resulting concurrent
        // SetReport calls collide and fail with kIOReturnExclusiveAccess (USB
        // never showed it, because it only ever attached once).
        demoTimer?.invalidate()
        demoTimer = nil
        let encoderBox = EncoderBox()
        let paint: @Sendable () -> Void = {
            let entries = (0..<6).map { id in
                MicroLightingEntry(
                    id: id,
                    c: 0xFF00FF,
                    b: 1,
                    e: MicroLightingEffect.rainbow.rawValue,
                    s: 1,
                    sa: id == 0 ? 1 : nil
                )
            }
            do {
                let request = try encoderBox.request(
                    method: "v.oai.thstatus", params: entries
                )
                for report in try MicroFraming.encode(request.payload) {
                    try transport.send(report: report)
                }
            } catch {
                stamped("lighting demo repaint failed: \(error.localizedDescription)")
            }
        }
        paint()
        stamped("LIGHTING DEMO: all six agent keys -> rainbow, ambient synced")
        let timer = Timer(timeInterval: 2, repeats: true) { _ in paint() }
        RunLoop.current.add(timer, forMode: .default)
        demoTimer = timer
    }

    private static func sendLightingSmoke(_ transport: IOHIDMicroTransport) throws {
        var encoder = MicroRPCEncoder()
        let entries = [
            MicroLightingEntry(
                id: 0,
                c: 0x0066FF,
                b: 1,
                e: MicroLightingEffect.breath.rawValue,
                s: 1
            ),
        ]
        let request = try encoder.request(method: "v.oai.thstatus", params: entries)
        for report in try MicroFraming.encode(request.payload) {
            try transport.send(report: report)
        }
    }

    private static func statusGlyph(_ status: AgentStatus) -> String {
        switch status {
        case .working: "✳"
        case .blocked: "‼"
        case .done: "✔"
        case .idle: "·"
        case .unknown: "?"
        }
    }

    private static func verifyLayoutBuilder() throws {
        let area = PaneLayoutRect(x: 4, y: 1, width: 145, height: 42)
        let right = PaneLayoutRect(x: 77, y: 1, width: 72, height: 42)
        let layout = PaneLayoutSnapshot(
            workspaceID: "w1",
            tabID: "w1:t1",
            zoomed: false,
            area: area,
            focusedPaneID: "w1:p1",
            panes: [
                PaneLayoutPane(
                    paneID: "w1:p1",
                    focused: true,
                    rect: PaneLayoutRect(x: 4, y: 1, width: 73, height: 42)
                ),
                PaneLayoutPane(
                    paneID: "w1:p2",
                    focused: false,
                    rect: PaneLayoutRect(x: 77, y: 1, width: 72, height: 21)
                ),
                PaneLayoutPane(
                    paneID: "w1:p3",
                    focused: false,
                    rect: PaneLayoutRect(x: 77, y: 22, width: 72, height: 21)
                ),
            ],
            splits: [
                PaneLayoutSplit(
                    id: "root",
                    direction: .right,
                    ratio: 0.5,
                    rect: area
                ),
                PaneLayoutSplit(
                    id: "right",
                    direction: .down,
                    ratio: 0.5,
                    rect: right
                ),
            ]
        )
        let expected = PaneLayoutNode.split(
            id: "root",
            direction: .right,
            ratio: 0.5,
            first: .pane("w1:p1"),
            second: .split(
                id: "right",
                direction: .down,
                ratio: 0.5,
                first: .pane("w1:p2"),
                second: .pane("w1:p3")
            )
        )
        guard PaneLayoutTreeBuilder.build(from: layout) == expected else {
            throw ProbeError.layoutSelfTestFailed
        }
    }
}

/// Thread-safe holder so one request-id sequence spans every repaint.
private final class EncoderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var encoder = MicroRPCEncoder()

    func request<Params: Encodable>(
        method: String,
        params: Params
    ) throws -> MicroRPCRequest {
        try lock.withLock { try encoder.request(method: method, params: params) }
    }
}

private final class ProbeMicroDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private var decoder = MicroFrameDecoder()
    private var joystick = MicroKeyMap.MicroJoystickTracker()

    /// Raw analog stick samples are folded into directional edges here, so the
    /// probe prints one press/release per gesture instead of a sample firehose.
    func consume(_ report: [UInt8]) -> [MicroInputEvent] {
        lock.withLock {
            decoder.consume(report).map(MicroRPCDecoder.decode).flatMap { event in
                guard case .joystickSample(let angle, let distance) = event else {
                    return [event]
                }
                return joystick.update(angle: angle, distance: distance).map {
                    MicroInputEvent.joystick(direction: $0.direction, state: $0.state)
                }
            }
        }
    }
}

private enum ProbeError: LocalizedError {
    case smokeMarkerMissing(String)
    case layoutSelfTestFailed
    case invalidLiveLayout

    var errorDescription: String? {
        switch self {
        case .smokeMarkerMissing(let paneID):
            "pane.send_input completed, but \(paneID) did not render the smoke marker"
        case .layoutSelfTestFailed:
            "nested split layout self-test failed"
        case .invalidLiveLayout:
            "one or more live layouts could not be converted into a complete pane tree"
        }
    }
}
