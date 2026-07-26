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

### Phase 3 — Worktrees & the codexspin loop
- Create worktree (branch / base) → open as space; open existing; remove.
- codexspin job → open its worktree (csws parity).

### Phase 4 — Sessions & remote herds (the differentiator)  ✅ shipped
- Runtime local named-session switcher, including create/start/stop.
- Remote herd over an SSH-forwarded Unix socket — reattach the full GUI and
  terminal panes to a remote daemon, the thing cmux can't do.
  (Remote path still needs a real host to confirm end-to-end.)

### Phase 5 — Settings & ecosystem  ✅ shipped
- Settings window (⌘,), themed: Appearance (terminal font family/size,
  notification defaults), Herdr Server (status · reload-config · update · stop),
  Plugins (list/enable/disable/unlink/logs), Integrations (install/uninstall),
  Config (edit `config.toml` · check · reload-server).
- Server "channel" control dropped — no herdr API/CLI for it.

### Phase 6 — Terminal power & layouts  ◑ mostly shipped
- ✅ Scrollback search (⌘F → SwiftTerm find bar via the responder chain).
- ✅ Broadcast input (one → many panes in a tab).
- ✅ Pane rename · process info.
- ⏸ Deferred: layout presets save/restore (`layout.apply` recreates split
  geometry but not the live agent processes a preset references — low value
  next to herdr's own live-session persistence) and multi-window / mission-
  control tiling (large, low marginal value).

## herdr reference (for implementers)

Socket `~/.config/herdr/herdr.sock` (newline JSON-RPC, `id` MUST be a string).
Terminal bridge: `herdr terminal attach <terminal_id> --takeover` (works for any
pane; `agent attach` needs a detected agent). `herdr api schema --json` is the
authoritative protocol. Structural ops corral drives via the `herdr` CLI
(`tab/pane/workspace/agent/worktree …`); reads via the socket snapshot + events.
Focus is **server-global** — always pass `--no-focus` on background ops.
