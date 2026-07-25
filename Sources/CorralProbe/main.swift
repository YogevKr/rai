import CorralCore
import Foundation

@main
struct CorralProbe {
    static func main() async {
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
                let marker = "CORRAL_SOCKET_SMOKE_OK_\(suffix)"
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
                Data("corral-probe: \(error.localizedDescription)\n".utf8)
            )
            Foundation.exit(1)
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
