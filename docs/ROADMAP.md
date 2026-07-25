# corral roadmap — driving herdr's full surface

corral is a native macOS GUI for the `herdr` multiplexer. herdr exposes ~99 API
methods across 16 domains; corral ships roughly a third today. This is the audit
and the value-ordered build plan (weighted for a herd of ~13 live agents, not for
effort). Interactive version: see the coverage artifact.

## Coverage snapshot

**Shipped** — live snapshot + coalesced events, the full pane model (split
geometry, draggable dividers, move/swap, zoom, click-to-focus, split-and-launch),
the keyboard layer (Tab/Pane/Space menus), and the interactive terminal
(`herdr terminal attach`, Dracula+ / Fira Code 16).

**Biggest gaps** — worktrees, named + remote (SSH) sessions, a real
notification/attention system, integrations, plugins, settings/preferences, and a
command palette.

## Build order

### Phase 1 — Navigate & command the herd
The daily cost at ~13 agents is *finding and acting on the right one*.
- **Command palette (⌘K)** — fuzzy-jump to any agent / tab / space.
- **Row context menu** — focus · rename · close · explain status.
- **Attention filter** — show only agents that need me (blocked).
- Rename / close / reorder tabs & spaces.

### Phase 2 — Never miss a blocked agent
- Native macOS notifications on blocked → done; click → raise corral + focus pane.
- Dock badge / menu-bar count of agents needing you.
- Sound + persisted global mute; per-pane do-not-disturb remains a follow-up.

Implementation note: `CorralApp` constructs one shared `CorralModel` and gives
it to both SwiftUI's `StateObject` and the `NSApplicationDelegateAdaptor`
delegate. The delegate and model then keep weak cross-references, avoiding a
second model or a retain cycle while allowing cold-launch notification routing.

### Phase 3 — Worktrees & the codexspin loop  ← current
- Create worktree (branch / base) → open as space; open existing; remove.
- codexspin job → open its worktree (csws parity).

### Phase 4 — Sessions & remote herds (the differentiator)
- Named-session switcher.
- Remote herd over SSH (`herdr --remote <target>`) — a GUI for a remote daemon,
  the thing cmux can't do.

### Phase 5 — Settings & ecosystem
- Preferences (theme · font · keybindings), edit `config.toml` (toast / sound /
  resume-on-restore), integrations manager, plugin manager, server controls
  (reload · update · channel).

### Phase 6 — Terminal power & layouts
- Scrollback search, broadcast input (one → many), layout presets + save/restore,
  pane rename / process info, multi-window / mission-control tiling.

## herdr reference (for implementers)

Socket `~/.config/herdr/herdr.sock` (newline JSON-RPC, `id` MUST be a string).
Terminal bridge: `herdr terminal attach <terminal_id> --takeover` (works for any
pane; `agent attach` needs a detected agent). `herdr api schema --json` is the
authoritative protocol. Structural ops corral drives via the `herdr` CLI
(`tab/pane/workspace/agent/worktree …`); reads via the socket snapshot + events.
Focus is **server-global** — always pass `--no-focus` on background ops.
