import Foundation

/// A palette row that does something instead of going somewhere.
///
/// ⌘K is the one surface a GUI user can reach without hunting a menu, so it
/// carries plugin actions too. Plugin *actions* run fine in rai — it is plugin
/// *panes* with popup placement that a non-TUI client cannot render — so this
/// is how the plugin ecosystem becomes reachable here.
struct PaletteCommand: Identifiable, Equatable {
    enum Effect: Equatable {
        case newTab
        case newSpace
        case splitRight
        case splitDown
        case zoomPane
        case closePane
        case closeTab
        case broadcast
        case reopenClosedTab
        case rescanRepos
        case refresh
        case plugin(actionID: String, pluginID: String)
    }

    let id: String
    let title: String
    let subtitle: String
    let effect: Effect

    static func builtIns() -> [PaletteCommand] {
        [
            PaletteCommand(
                id: "command:new-tab",
                title: "New Tab",
                subtitle: "Command · in this space",
                effect: .newTab
            ),
            PaletteCommand(
                id: "command:new-space",
                title: "New Space",
                subtitle: "Command · empty",
                effect: .newSpace
            ),
            PaletteCommand(
                id: "command:split-right",
                title: "Split Right",
                subtitle: "Command · pane",
                effect: .splitRight
            ),
            PaletteCommand(
                id: "command:split-down",
                title: "Split Down",
                subtitle: "Command · pane",
                effect: .splitDown
            ),
            PaletteCommand(
                id: "command:zoom-pane",
                title: "Zoom Pane",
                subtitle: "Command · pane",
                effect: .zoomPane
            ),
            PaletteCommand(
                id: "command:close-pane",
                title: "Close Pane",
                subtitle: "Command · pane",
                effect: .closePane
            ),
            PaletteCommand(
                id: "command:close-tab",
                title: "Close Tab",
                subtitle: "Command · reopen with ⌘⇧T",
                effect: .closeTab
            ),
            PaletteCommand(
                id: "command:broadcast",
                title: "Broadcast to Tab",
                subtitle: "Command · every pane",
                effect: .broadcast
            ),
            PaletteCommand(
                id: "command:reopen-closed-tab",
                title: "Reopen Closed Tab",
                subtitle: "Command · undo close",
                effect: .reopenClosedTab
            ),
            PaletteCommand(
                id: "command:rescan-repos",
                title: "Rescan Repos",
                subtitle: "Command · project roots",
                effect: .rescanRepos
            ),
            PaletteCommand(
                id: "command:refresh",
                title: "Refresh",
                subtitle: "Command · reload snapshot",
                effect: .refresh
            ),
        ]
    }

    /// Plugin actions become commands with the plugin named in the subtitle, so
    /// two plugins offering "Open Picker" stay tellable apart.
    static func from(_ action: PluginAction) -> PaletteCommand {
        PaletteCommand(
            id: "command:plugin:\(action.pluginId).\(action.id)",
            title: action.title,
            subtitle: action.description.map { "Plugin · \(action.pluginId) · \($0)" }
                ?? "Plugin · \(action.pluginId)",
            effect: .plugin(actionID: action.id, pluginID: action.pluginId)
        )
    }
}
