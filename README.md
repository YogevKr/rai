# corral

A native macOS window for your **[herdr](https://herdr.dev)** herd — the desktop
GUI that's currently missing. herdr is a great agent multiplexer, but its
frontend is a TUI. `corral` is a thin native client over herdr's socket API: a
real AppKit/SwiftUI window with a sidebar, tabs, splits, drag, and per-pane
terminals — driving the **unchanged** herdr daemon underneath.

> Working name (a corral holds the herd). Rename freely.

## Why this can exist (and why it's a gap)

herdr already exposes everything a GUI needs over its unix socket
(`~/.config/herdr/herdr.sock`), newline-delimited JSON, `{id, method, params}`:

- **`session.snapshot`** — the full tree: workspaces → tabs → panes, focus,
  agent status, worktree/repo per workspace. (Drives the sidebar.)
- **`events.subscribe`** — live deltas: `layout.updated`, `pane.created/closed/
  moved/focused`, `pane.agent_status_changed`, `pane.output_changed`,
  `tab.closed`. (Keeps the UI live without polling.)
- **`pane.send_input`**, **`pane.resize`** — drive a pane.
- **`pane.read` (`--format ansi`)** / the `terminal` frame-attach stream —
  render a pane's content.
- **`layout.set_split_ratio` / `layout.apply` / `layout.export`** — read & drive
  splits. **`agent.*`** — status, read, send, start, focus.

So the app is fundamentally: **socket client + terminal widget**. No herdr fork,
no runtime patches. The only existing frontend anyone built is mobile (Collie,
a Tailscale PWA). The single-window native Mac client doesn't exist yet.

This is deliberately **not** the reverted `ghostherd` approach (which
AppleScript-spawned real Ghostty tabs). corral renders panes *inside its own
window* from the socket stream — one window, one process, no terminal-app
puppetry.

## Prior art: cmux (why not just use it?)

[cmux](https://cmux.com) (manaflow-ai/cmux, GPL) is a native macOS Swift/AppKit
terminal on **libghostty** with a vertical-tab sidebar, notification rings, split
panes, an in-app browser, a Unix-socket API, and session restore — almost exactly
this app's shape. **But cmux is its own multiplexer, not a herdr frontend**, and
its persistence model is fundamentally weaker for the daemon/remote case:

- **herdr = live daemon.** Detach and the processes *keep running*; reattach to
  the same live, mid-flight process, locally or over SSH (`herdr --remote`).
- **cmux = save + resume.** A GUI app: quit/reboot stops the processes, and on
  relaunch cmux *rebuilds the layout and re-runs each agent's native resume*
  (`claude --resume`, `codex resume`). Great "reopen and it's back" UX, but a
  reconstruction, not a live daemon, and no remote-daemon-over-SSH.

So corral exists to keep herdr's daemon-grade detach + remote + plugin/agent
ecosystem, and add the GUI cmux has. The terminal-emulation itself is **reused,
not built**: `libghostty-vt` (Ghostty's core, alpha C API, fed external/remote VT
bytes — see Ghostty's "Reconnectable Terminal" prototype, disc #12176) or
**SwiftTerm** for v1. Only the herdr-binding shell is new.

## Architecture

```
  herdr daemon (unchanged)
        │  unix socket: ~/.config/herdr/herdr.sock  (newline JSON-RPC + event stream)
        ▼
  corral (native macOS app)
   ├─ HerdrClient        session.snapshot + events.subscribe → an observable model
   ├─ Sidebar/Tabs/Split  SwiftUI/AppKit views bound to that model
   └─ PaneView            terminal widget:
                            content  ← pane.read(ansi) / terminal frame stream
                            keystrokes → pane.send_input
                            resize     → pane.resize
```

## Stack decisions

- **Swift + AppKit/SwiftUI** — native single-window Mac app (the stated want).
- **Terminal widget:** start with **SwiftTerm** (MIT, trivially fed external
  bytes — perfect for a remote PTY over the socket). **libghostty** is the
  stretch goal (GPU, matches Ghostty) *if* its embedding API accepts an external
  byte source rather than owning its own PTY — prove that before committing.
- **Transport:** raw `AF_UNIX` `SOCK_STREAM`, one connection for RPC + one for the
  event stream (events keep the socket open and push).

## Roadmap

- **P0 — de-risk (this repo, `poc/`):** a socket client that snapshots the tree,
  streams events, reads a pane, and sends it input. Proves the whole loop from a
  script before any Swift. ✅ started.
- **P1 — MVP:** Swift window; sidebar from `session.snapshot`, kept live by
  `events.subscribe`; **one interactive pane** (type into it, see output) via
  SwiftTerm + `pane.send_input` + a content stream.
- **P2:** tabs + splits (render `layout`, drive `set_split_ratio`), focus, agent
  status glyphs, `pane.close`/`create`.
- **P3:** drag to move/split panes, workspace switching, agent actions
  (`agent.send/start/attach`), native notifications on `blocked`/`done`.
- **P4 (stretch):** swap SwiftTerm → libghostty; remote herdr over SSH
  (`herdr --remote`).

## Run the PoC

```sh
poc/herdr_client.py tree              # render the live workspace/tab/pane tree
poc/herdr_client.py watch             # stream live events
poc/herdr_client.py read  <pane_id>   # dump a pane's recent content
poc/herdr_client.py send  <pane_id> "echo hi\n"   # send input to a pane
```

Requires a running herdr server (`herdr` / `herdr server`).
