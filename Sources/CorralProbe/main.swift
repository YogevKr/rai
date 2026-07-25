import CorralCore
import Foundation

@main
struct CorralProbe {
    static func main() async {
        let client = HerdrClient()
        do {
            let snapshot = try await client.snapshot()
            print(
                "herdr \(snapshot.version) · protocol \(snapshot.protocol) · "
                    + "\(snapshot.workspaces.count) workspaces"
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
}

private enum ProbeError: LocalizedError {
    case smokeMarkerMissing(String)

    var errorDescription: String? {
        switch self {
        case .smokeMarkerMissing(let paneID):
            "pane.send_input completed, but \(paneID) did not render the smoke marker"
        }
    }
}
