import SwiftUI

/// Commands the composer can offer per agent. Modeled after what the agents
/// actually accept; `takesArgs` inserts into the compose field instead of
/// sending, `dangerous` requires a second tap.
struct AgentCommand: Identifiable {
    let name: String
    let summary: String
    var takesArgs = false
    var dangerous = false

    var id: String { name }
}

enum AgentCommands {
    static func commands(for agent: String?) -> [AgentCommand] {
        switch agent {
        case "claude":
            return claude
        case "codex":
            return codex
        default:
            return []
        }
    }

    static let claude: [AgentCommand] = [
        .init(name: "compact", summary: "Compact the conversation"),
        .init(name: "clear", summary: "Clear history", dangerous: true),
        .init(name: "rename", summary: "Rename this session", takesArgs: true),
        .init(name: "model", summary: "Show or switch model", takesArgs: true),
        .init(name: "resume", summary: "Resume a session", takesArgs: true),
        .init(name: "status", summary: "Session status"),
        .init(name: "cost", summary: "Token usage and cost"),
        .init(name: "context", summary: "Context window usage"),
        .init(name: "todos", summary: "Show the task list"),
        .init(name: "review", summary: "Review a pull request", takesArgs: true),
        .init(name: "memory", summary: "Edit memory files"),
        .init(name: "config", summary: "Open config"),
        .init(name: "permissions", summary: "Manage permissions"),
        .init(name: "agents", summary: "Manage subagents"),
        .init(name: "mcp", summary: "MCP servers"),
        .init(name: "hooks", summary: "Manage hooks"),
        .init(name: "bashes", summary: "Background tasks"),
        .init(name: "export", summary: "Export the conversation", takesArgs: true),
        .init(name: "rewind", summary: "Rewind conversation/code"),
        .init(name: "add-dir", summary: "Add a working directory", takesArgs: true),
        .init(name: "init", summary: "Write CLAUDE.md"),
        .init(name: "doctor", summary: "Health check"),
        .init(name: "help", summary: "Show help"),
        .init(name: "bug", summary: "Report a bug", takesArgs: true),
        .init(name: "release-notes", summary: "Show release notes"),
        .init(name: "pr-comments", summary: "Show PR comments"),
        .init(name: "security-review", summary: "Security review of changes"),
        .init(name: "vim", summary: "Toggle vim editing mode"),
        .init(name: "exit", summary: "Quit Claude", dangerous: true),
    ]

    static let codex: [AgentCommand] = [
        .init(name: "new", summary: "Start a new chat", dangerous: true),
        .init(name: "compact", summary: "Summarize to save context"),
        .init(name: "diff", summary: "Show git diff"),
        .init(name: "status", summary: "Session configuration"),
        .init(name: "model", summary: "Choose model and effort"),
        .init(name: "approvals", summary: "Approval mode"),
        .init(name: "review", summary: "Review current changes"),
        .init(name: "mention", summary: "Mention a file", takesArgs: true),
        .init(name: "init", summary: "Write AGENTS.md"),
        .init(name: "mcp", summary: "MCP servers"),
        .init(name: "undo", summary: "Undo last turn's edits", dangerous: true),
        .init(name: "logout", summary: "Log out of Codex", dangerous: true),
        .init(name: "quit", summary: "Exit Codex", dangerous: true),
    ]
}

/// Two-tap guard for shell input that can destroy things. Substring checks on
/// purpose — cheap, predictable, and false positives only cost one extra tap.
enum DestructiveInput {
    private static let needles = [
        "rm -r", "rm -f", "rm -fr", "rm -rf",
        "sudo ",
        "git push --force", "git push -f", "git reset --hard",
        "git clean -f", "git checkout --",
        "dd if=", "mkfs",
        "chmod -r 777", "chown -r",
        "> /etc/", "> /usr/", "> /system/", "> /library/",
        "shutdown", "reboot",
        "kill -9",
        "drop table", "truncate table",
    ]

    static func isDestructive(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return needles.contains { lowered.contains($0) }
    }
}

/// One-tap answers for the prompts agents ask most.
struct QuickReplyRow: View {
    let send: (String) -> Void

    private static let replies: [(label: String, text: String)] = [
        ("Yes", "yes"),
        ("No", "no"),
        ("Continue", "continue"),
        ("Commit & push", "commit and push"),
        ("Retry", "retry"),
        ("Skip", "skip"),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.replies, id: \.label) { reply in
                    Button(reply.label) { send(reply.text) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }
}

struct CommandPaletteSheet: View {
    let agent: String?
    /// Insert "/cmd " into the compose field (commands that take arguments).
    let insert: (String) -> Void
    /// Send "/cmd" to the pane immediately.
    let sendNow: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var armedCommand: String?

    private var commands: [AgentCommand] {
        let all = AgentCommands.commands(for: agent)
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return all }
        return all.filter {
            $0.name.lowercased().contains(trimmed)
                || $0.summary.lowercased().contains(trimmed)
        }
    }

    var body: some View {
        NavigationStack {
            List(commands) { command in
                Button {
                    tap(command)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("/\(command.name)")
                                .font(.body.monospaced())
                                .foregroundStyle(
                                    command.dangerous && armedCommand != command.name
                                        ? Color.red
                                        : Color.primary
                                )
                            Text(command.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if armedCommand == command.name {
                            Text("Tap again")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.red)
                        } else if command.takesArgs {
                            Image(systemName: "text.cursor")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle("Commands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay {
                if commands.isEmpty {
                    ContentUnavailableView {
                        Label(
                            agent == nil ? "No agent in this pane" : "No matches",
                            systemImage: "slash.circle"
                        )
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func tap(_ command: AgentCommand) {
        if command.dangerous, armedCommand != command.name {
            armedCommand = command.name
            return
        }
        if command.takesArgs {
            insert("/\(command.name) ")
        } else {
            sendNow("/\(command.name)")
        }
        dismiss()
    }
}
