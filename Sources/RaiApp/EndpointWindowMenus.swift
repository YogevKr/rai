import RaiCore
import SwiftUI

/// These controls use only the focused window's connection and snapshot.
struct EndpointActionButton: View {
    @ObservedObject var model: EndpointWindowModel
    let title: String
    let method: String
    var params: [String: JSONValue] = [:]

    var body: some View {
        Button(title) { model.perform(method, params: params) }
            .disabled(model.busy || model.snapshot == nil || !model.methods.contains(method))
            .help(model.methods.contains(method) ? title : "This server does not support this action.")
    }
}

struct EndpointTabMenu: View {
    @ObservedObject var model: EndpointWindowModel

    var body: some View {
        if let snapshot = model.snapshot, let workspace = snapshot.focusedWorkspaceID {
            EndpointActionButton(model: model, title: "New Tab", method: "tab.create",
                                 params: ["workspace_id": .string(workspace), "focus": .bool(true)])
                .keyboardShortcut("t", modifiers: .command)
            if let tab = snapshot.focusedTabID {
                EndpointActionButton(model: model, title: "Close Tab", method: "tab.close", params: ["tab_id": .string(tab)])
            }
            Divider()
            ForEach(snapshot.tabs.indices, id: \.self) { index in
                let tab = snapshot.tabs[index].objectValue ?? [:]
                if tab["workspace_id"]?.stringValue == workspace, let id = tab["tab_id"]?.stringValue {
                    EndpointActionButton(model: model, title: tab["label"]?.stringValue ?? id,
                                         method: "tab.focus", params: ["tab_id": .string(id)])
                }
            }
        }
    }
}

struct EndpointPaneMenu: View {
    @ObservedObject var model: EndpointWindowModel

    var body: some View {
        if let pane = model.snapshot?.focusedPaneID {
            EndpointActionButton(model: model, title: "Split Right", method: "pane.split",
                                 params: ["target_pane_id": .string(pane), "direction": .string("right"), "focus": .bool(true)])
                .keyboardShortcut("d", modifiers: .command)
            EndpointActionButton(model: model, title: "Split Down", method: "pane.split",
                                 params: ["target_pane_id": .string(pane), "direction": .string("down"), "focus": .bool(true)])
                .keyboardShortcut("d", modifiers: [.command, .shift])
            EndpointActionButton(model: model, title: "Close Pane", method: "pane.close", params: ["pane_id": .string(pane)])
            EndpointActionButton(model: model, title: "Zoom Pane", method: "pane.zoom",
                                 params: ["pane_id": .string(pane), "mode": .string("toggle")])
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            Divider()
            if model.methods.contains("pane.scroll") {
                Button("History Page Up") { model.scrollPage(1) }.disabled(model.busy)
            Button("History Page Down") { model.scrollPage(-1) }.disabled(model.busy)
                Button("Return to Live Output") { model.scroll(paneID: pane, offset: 0) }.disabled(model.busy)
            }
            Divider()
            ForEach(["left", "right", "up", "down"], id: \.self) { direction in
                EndpointActionButton(model: model, title: "Focus \(direction.capitalized)", method: "pane.focus_direction",
                                     params: ["pane_id": .string(pane), "direction": .string(direction)])
            }
        }
    }
}

struct EndpointSpaceMenu: View {
    @ObservedObject var model: EndpointWindowModel

    var body: some View {
        if let snapshot = model.snapshot, let workspace = snapshot.focusedWorkspaceID {
            EndpointActionButton(model: model, title: "New Space", method: "workspace.create",
                                 params: ["source_workspace_id": .string(workspace), "focus": .bool(true)])
                .keyboardShortcut("n", modifiers: .command)
            Divider()
            ForEach(snapshot.workspaces.indices, id: \.self) { index in
                let item = snapshot.workspaces[index].objectValue ?? [:]
                if let id = item["workspace_id"]?.stringValue {
                    EndpointActionButton(model: model, title: item["label"]?.stringValue ?? id,
                                         method: "workspace.focus", params: ["workspace_id": .string(id)])
                }
            }
        }
    }
}
