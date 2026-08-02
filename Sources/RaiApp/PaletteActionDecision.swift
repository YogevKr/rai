import AppKit
import Foundation

/// Modifier state at the moment Return is pressed, free of AppKit so the
/// mapping can be tested without an event loop.
struct PaletteModifiers: Equatable {
    var option = false
    var shift = false
    var command = false

    static let none = PaletteModifiers()

    init(option: Bool = false, shift: Bool = false, command: Bool = false) {
        self.option = option
        self.shift = shift
        self.command = command
    }

    init(_ flags: NSEvent.ModifierFlags) {
        self.init(
            option: flags.contains(.option),
            shift: flags.contains(.shift),
            command: flags.contains(.command)
        )
    }
}

/// Which action Return performs on the selected palette row.
///
/// Every modifier degrades to `.open` when the row cannot support it. A palette
/// that silently does nothing is worse than one that does the obvious thing, and
/// the row's badge already tells the user what "open" means for that kind.
enum PaletteActionDecision {
    static func requested(_ modifiers: PaletteModifiers) -> CommandPaletteItem.Action {
        // One modifier wins, in this order, so a stray extra key still lands on
        // a defined action rather than an accidental combination.
        if modifiers.option { return .newWorktree }
        if modifiers.shift { return .newTab }
        if modifiers.command { return .revealInFinder }
        return .open
    }

    static func supports(
        _ action: CommandPaletteItem.Action,
        kind: CommandPaletteItem.Kind,
        hasPath: Bool,
        isRemote: Bool
    ) -> Bool {
        switch action {
        case .open:
            return true
        case .newTab:
            // A repo has no space yet, so there is no tab strip to add to, and
            // a command is not a place you can put a tab in.
            return kind == .workspace || kind == .agent
        case .newWorktree:
            return hasPath
        case .revealInFinder:
            // A remote herd's paths live on the other machine; Finder would
            // open the wrong thing, or nothing.
            return hasPath && !isRemote
        }
    }

    static func resolved(
        modifiers: PaletteModifiers,
        item: CommandPaletteItem,
        isRemote: Bool
    ) -> CommandPaletteItem.Action {
        let action = requested(modifiers)
        let hasPath = !(item.matchPath ?? "").isEmpty
        guard supports(action, kind: item.kind, hasPath: hasPath, isRemote: isRemote) else {
            return .open
        }
        return action
    }
}
