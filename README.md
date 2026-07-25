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

## macOS MVP

The SwiftPM package builds both the native app and a headless socket probe:

```sh
swift build
swift run corral-probe
swift run corral
```

`corral` targets macOS 14 or newer. It connects to
`~/.config/herdr/herdr.sock` by default; set `HERDR_SOCKET_PATH` to override
the path. The probe prints the live workspace → tab → pane tree, then reads the
focused pane through the same `HerdrClient` used by the app.

For explicit transport checks against a disposable or known-idle shell pane:

```sh
swift run corral-probe --watch
swift run corral-probe --send-smoke <pane-id>
```

The app currently renders one selected pane at a time. Workspace/tab/pane
creation, focus, movement, closure, and agent status updates arrive on the
event connection and are coalesced before updating SwiftUI. Herdr protocol 16
does not expose `pane.output_changed` as a subscribable event, so the selected
pane uses `pane.updated` plus a 700 ms `pane.read` fallback poll. Protocol 16's
`pane.resize` is directional split resizing rather than a terminal
rows/columns report, so view resizing is intentionally not forwarded.
