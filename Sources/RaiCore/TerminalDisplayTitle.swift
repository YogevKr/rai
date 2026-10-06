import Foundation

/// Display policy only. Keep the original title and session ID in the snapshot.
public enum TerminalDisplayTitle {
    public static func text(_ title: String?, agent: String?) -> String? {
        guard let title = AgentTitleGlyphs.strip(title?.trimmingCharacters(in: .whitespacesAndNewlines))?
            .trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        // Codex emits its session UUID when no conversation name is available.
        // It is an identity, not a useful task title. Explicit tab names bypass
        // this rule, as do UUID titles from shells and other programs.
        if agent?.lowercased() == "codex", UUID(uuidString: title) != nil { return nil }
        return title
    }
}

public extension Pane {
    var displayTerminalTitle: String? {
        TerminalDisplayTitle.text(terminalTitleStripped, agent: agent)
            ?? TerminalDisplayTitle.text(terminalTitle, agent: agent)
    }
}
