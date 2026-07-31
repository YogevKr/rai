# herdr → rai: parity audit

What herdr's own TUI does that rai does not. Identification only — nothing here
is implemented, and nothing here is a commitment to implement it.

Audited 2026-07-31 against herdr 0.7.4 (protocol 16, source checkout at
`~/.agents/skills/herdr`) and rai v0.1.29 + the unreleased agents panel.

Method coverage: herdr exposes **75 socket methods**; rai drives **43** of them,
by socket for the hot path (`session.snapshot`, `events.subscribe`, `pane.read`,
`pane.send_input`, `pane.focus/resize/move/zoom`) and by CLI for the rest.
Companion audits: [collie-gap.md](collie-gap.md) (phone), [ROADMAP.md](ROADMAP.md)
(build order).

---

## Tier 1 — plugins are half-blind in rai

herdr's plugin contract is not only "run a command". Plugins also send requests
*to the UI*, and rai implements none of them. A plugin that works in the TUI can
silently do nothing in rai — the worst failure mode here, because it looks like
the plugin is broken.

1. **Plugin command placements.** A plugin command declares
   `placement = overlay | popup | split | tab | zoomed`. rai handles the pane-ish
   ones by accident (they become panes) but has no surface for `popup` or
   `overlay`: herdr documents a popup as "a singleton session resource rather
   than a Herdr pane", so it never appears in `session.snapshot` and rai cannot
   render it at all. `popup.close` is likewise unimplemented.
2. **`ui.toast`** — plugins raise transient toasts. rai has no toast surface, so
   the message is dropped.
3. **`ui.sound`, `ui.sound.path`, `ui.sound.done_path`, `ui.sound.request_path`**
   — plugin-requested sounds, and herdr's per-agent sound config (separate paths
   for claude, codex, gemini, cursor, amp, cline, opencode, droid, grok, kimi,
   kiro, …, each with done/request variants). rai plays only its own
   notification sound.
4. **`notification.show`** — the API any plugin or script uses to raise a
   notification through herdr. rai synthesises notifications from its own status
   transitions and ignores this method, so plugin-authored notifications never
   reach the Mac.
5. **`client.window_title.set` / `client.window_title.clear`** — herdr lets the
   session drive the client window title. rai's title is static.
6. **Agent views** (`AgentViewSetParams`: source, label, filter tree, multi-field
   sort). A plugin can install a *named, filtered, sorted* agent list — herdr
   renders it in the agents panel and labels it "filtered". The agents panel I
   just built implements only the two built-in sorts (priority / grouped), so a
   plugin-defined view is ignored.
7. **Plugin installation.** rai does list / enable / disable / unlink / log /
   action. herdr's CLI also has `install`, `link`, `uninstall`, `commands`,
   `pane`, `config-dir` — so rai can manage plugins you already have but cannot
   add one, and has no marketplace path.

## Tier 2 — snapshot data rai decodes but never uses

Cheap wins: the bytes are already on the wire.

8. **`snapshot.agents`** — a top-level array (7 entries in the live herd) that
   rai's `SessionSnapshot` does not decode at all. It is the agent-only
   projection of panes, and it is what herdr's own agents panel is built from.
9. **`pane.agent_session`** — `{agent, kind, source, value}`, e.g. Claude's
   session UUID. This is the handle for resuming a specific agent conversation.
   rai's "reopen closed tab resumes the agent with its original flags" rebuilds
   the command line instead; the session id would let it resume the actual
   session.
10. **`worktree.repo_key` / `repo_root`** — rai decodes only `repo_name`,
    `checkout_path`, `is_linked_worktree`. `repo_key` is exactly what herdr
    groups worktree spaces by (see #12).

## Tier 3 — sidebar and presentation

11. **Git branch + ahead/behind in the space row.** herdr's default space layout
    is two rows: `[state icon, workspace]` then `[branch, git_status]`. rai shows
    a worktree tag and no branch or ahead/behind counts. Note this data is *not*
    in the snapshot — herdr polls git itself, so rai would have to as well.
12. **Grouped worktree spaces.** herdr collapses every space sharing a `repo_key`
    under one parent row, indents the children, renames them to their branch
    (`grouped_child_display_label` strips `worktree/`), and remembers collapsed
    groups (`collapsed_space_keys`). rai lists every space flat.
13. **Configurable sidebar rows.** herdr's `[sidebar.agents]` / `[sidebar.spaces]`
    let you compose rows from tokens (state icon, state text, workspace, tab,
    pane, agent, terminal title, branch, git status, custom metadata) with
    per-token styling, **including per-agent overrides** (`rows_by_agent`). rai
    hardcodes its row layout.
14. **Custom metadata tokens** — `workspace.report_metadata` and
    `pane.report_metadata` let plugins attach arbitrary key/values that the
    sidebar renders as tokens. rai ignores both, so plugin badges never show.
15. **Custom agent labels and custom status labels** (config). rai hardcodes
    both.
16. **herdr's theme config.** rai ships its own Dracula+ theme and font settings
    and does not read herdr's `[theme]`, so a user who themed herdr sees two
    different colour schemes.

## Tier 4 — terminal and interaction

17. **Copy mode.** herdr has a full modal copy mode: vim motions
    (`h/j/k/l`, `w/b/e`, `{`/`}`), `v`/`space` to start a visual selection,
    `y`/`enter` to yank, and in-mode search with match counts. rai has
    mouse selection (which does page herdr-side scrollback — genuinely good) and
    ⌘F search, but no keyboard-driven selection at all.
18. **Edit scrollback in `$EDITOR`** — herdr dumps the pane buffer into an
    editor. No rai equivalent.
19. **Indexed agent jumps** (`focus agent 1-9`) — herdr jumps to the Nth *agent*;
    rai's ⌘1-9 selects the Nth *tab* in the current space. With the new agents
    panel this now has an obvious home.
20. **Kitty graphics.** herdr renders inline images (`src/kitty_graphics.rs`).
    rai's SwiftTerm handles the kitty *keyboard* protocol only, so image output
    from an agent does not render.
21. **Custom command keybindings.** herdr binds arbitrary shell commands, a
    `type` action that types literal text, plugin actions, and a whole
    prefix/resize/navigate modal layer, all user-configurable. rai's shortcuts
    are fixed at compile time.

## Tier 5 — lifecycle and server

22. **`server.live_handoff`** — hand live panes to a new local server (how herdr
    upgrades itself without killing agents). rai's Settings offers "Update
    herdr", which is the blunt version.
23. **Update channel.** `herdr channel set stable|preview` exists in the CLI;
    ROADMAP.md line 53 says channel control was dropped for lack of an API. That
    is now stale — it is a two-line settings addition.
24. **`server.agent_manifests` / `reload_agent_manifests`** — inspect and refresh
    the agent-detection manifests. No rai surface; when detection is wrong today
    there is nothing to look at.
25. **Agent authority overrides** — `pane.report_agent`,
    `pane.report_agent_session`, `pane.clear_agent_authority`,
    `pane.release_agent`. herdr lets you correct or release what it thinks is
    running in a pane; rai has no override, so a misdetected pane stays
    misdetected.
26. **Release notes and product announcements.** herdr ships
    `release_notes.rs` + `product_announcements.rs` and maintains
    `~/.config/herdr/release-notes.json`. rai never surfaces them — the user
    upgrades herdr underneath rai and sees nothing.
27. **Automation primitives** — `agent.wait`, `pane.wait_for_output`,
    `events.wait`, `agent.prompt`. Legitimately CLI-shaped; listed for
    completeness, not as a GUI gap.

---

## Not gaps (checked, rai already has these)

Directional pane focus (⌥⌘arrows), pane swap by drag, worktree
create/open/remove, scrollback selection that pages herdr-side history,
scrollback search, broadcast input, pane process info, plugin actions and logs,
integrations install/uninstall, named + remote sessions, config check/edit,
command palette, attention filter, notifications with dock badge.

rai is also ahead of the TUI in places: real terminal panes with drag-and-drop
layout, an iPhone companion with push, image paste, and — as of the unreleased
build — starting the herdr server itself.
