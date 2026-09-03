# Testing & end-to-end verification

How to build, run, screenshot, and end-to-end verify rai against a live `herdr`
daemon — without disrupting anyone's running agents.

## Build & run a dev build

`scripts/bundle.sh` compiles a release build, wraps it in `Rai.app`, code-signs
it, and installs to `/Applications` (falling back to `~/Applications`).

```sh
./scripts/bundle.sh          # arm64 dev build → /Applications/Rai.app
open -a Rai
```

Env overrides:

| var | effect |
| --- | --- |
| `RAI_VERSION` | `CFBundleShortVersionString` (default `0.1.0`) |
| `RAI_UNIVERSAL=1` | universal arm64 + x86_64 binary (used by the release workflow) |
| `RAI_APP_DEST` | install into this dir instead of `/Applications` |
| `RAI_SIGN_IDENTITY` | codesign identity. A stable local identity (e.g. a self-signed `rai-dev-signing`) keeps macOS TCC grants — like Input Monitoring for the Codex Micro — alive across rebuilds, because the code requirement stays constant. Falls back to ad-hoc when the identity is absent (CI, other machines). |
| `RAI_PAIRING_CODE_FILE` | Test harness only: the bridge mirrors its current pairing code (one line; empty once spent) to this owner-only file, so an isolated end-to-end run can pair a simulator without driving Settings. Unset in normal use. Pair the simulator with `SIMCTL_CHILD_RAI_PAIR_URL="rai://pair?host=localhost&port=<RAI_BRIDGE_PORT>&code=<code>"`. Run the isolated instance with `open -n -a <bundle> --env HOME=<scratch> …` so its UserDefaults stay out of the real ones (its Application Support folder is still the real one — delete `bridge-audit.jsonl` and `hooks.sock` afterwards). |

For a quick loop without bundling, `swift run rai` runs straight from the package.

## Unit tests

```sh
swift test
```

Heads-up: the Homebrew Swift toolchain frequently lacks XCTest, so `swift test`
can fail locally with an XCTest/linker error even when the code is fine. In that
case `swift build` is the local compile gate, and CI is the source of truth —
`.github/workflows/ci.yml` runs the full suite on `macos-15` with Xcode 16.x
(pinned because SwiftTerm ships a `.metal` shader that only the Xcode-bundled
Metal toolchain can compile).

## Typing latency benchmark

`rai-bench --latency` hosts one terminal view. It runs 200 samples for each
path. The terminal path sends an `NSEvent` through `TerminalView.keyDown`.
The delegate feeds the sent byte back as its echo. The timer stops in
SwiftTerm's `rangeChanged` display-update callback.

The prediction path starts its timer before the same synthetic key dispatch.
It uses the production `PredictionOverlayView` and stops after its `draw` callback.

Use the app's default CoreGraphics renderer:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift run --scratch-path .build-tests rai-bench --latency --renderer cg
```

Run the baseline without rai's small-feed decision:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift run --scratch-path .build-tests rai-bench --latency --renderer cg \
  --no-fast-path
```

`--no-fast-path` does not bypass `TerminalView` input handling. SwiftTerm still
uses its own recent-input fast path. This matches production before rai's
size guard. Use `--samples N` to change the sample count.

The isolated lab measures the separate herdr attach cost:

```sh
scripts/herdr-lab.sh start
RAI_LAB_SOCKET=$(scripts/herdr-lab.sh socket)
RAI_LAB_TERMINAL=$(HERDR_SOCKET_PATH="$RAI_LAB_SOCKET" herdr api snapshot \
  | jq -r '.result.snapshot.panes[0].terminal_id')
scripts/attach-latency.py "$RAI_LAB_SOCKET" "$RAI_LAB_TERMINAL" 60
scripts/herdr-lab.sh stop
```

Results from 2026-09-03 used a debug build on the same Mac:

| Path | Samples | Baseline median / p90 | Guarded median / p90 |
| --- | ---: | ---: | ---: |
| terminal key to display update | 200 | 0.372 / 0.495 ms | 0.237 / 0.393 ms |
| key to prediction overlay draw | 200 | 0.434 / 0.567 ms | 0.406 / 0.518 ms |

The baseline command used `--no-fast-path`. The guarded command omitted it.
The fast-path flag does not change the prediction path. Its difference is
run noise.

The guarded terminal path cut the median by 0.135 ms, or 36%.
It cut p90 by 0.102 ms, or 21%. The prediction differences are run noise.

The baseline terminal range was 0.163–3.010 ms. The guarded range was
0.150–0.548 ms.

Three fresh isolated-lab runs used 60 samples each:

| Run | Median | p90 |
| --- | ---: | ---: |
| 1 | 20.3 ms | 22.2 ms |
| 2 | 20.1 ms | 25.1 ms |
| 3 | 4.4 ms | 22.3 ms |

The combined range was 0.6–30.5 ms. Most echoes complete below 5 ms.
About one in ten waits for a 20–30 ms daemon tick. A smoothed center can
remain below 8 ms and miss this tail.

Local prediction now uses the maximum of the last 20 confirmed echoes.
The 8 ms threshold detects a recent daemon-tick delay. Display still requires
a confirmed echo in the current burst.

Local prediction is off by default. The measured local echo was about 4 ms
median and 22 ms p90 in the fast-median run. A silent `read -s` transition
cannot revoke confidence through output because it emits no bytes. Enable
**Predict local typing** under Settings → Appearance only after accepting this
risk. The harness commands above measure the opt-in rendering paths.

The four-pane CPU guard used 200,000 bytes per second for 20 seconds.
CoreGraphics used 88.6% CPU in the earlier baseline and 67.3% now. The feeds
were 3.3 MB and 3.8 MB. That feed difference prevents a strict CPU comparison.
The current run used 13.47 CPU seconds over 20.01 wall seconds. Unit tests
confirm that 512-byte and larger feeds retain the frame-limited path.

Metal remains off by default. The harness used aggregated buffering and 200
samples. These results stop at SwiftTerm's display-update callback:

| Metal settings | Median | p90 |
| --- | ---: | ---: |
| transaction off, display sync on | 0.253 ms | 0.460 ms |
| transaction on, display sync on | 0.219 ms | 0.373 ms |
| transaction off, display sync off | 0.228 ms | 0.366 ms |

Run these variants with `--metal-presents-with-transaction` and
`--metal-display-sync off`. The callback precedes GPU presentation. Therefore
these small differences do not prove a scanout change. Rai keeps SwiftTerm's
defaults. It keeps display sync on because disabled sync can tear.

## Screenshot the running app

Bring rai to the front, read its window bounds, and capture just that window:

```sh
osascript -e 'tell application "Rai" to activate'
RECT=$(osascript -e 'tell application "System Events" to tell process "Rai" \
  to get {position, size} of front window' | tr -d ' ')   # → "x,y,w,h"
screencapture -x -o -R"$RECT" rai.png
```

- The `System Events` step needs **Accessibility** permission for the terminal
  running it. If it's denied, fall back to a full-screen grab:
  `screencapture -x -o rai.png`.
- `-x` silences the shutter; `-o` drops the window shadow.
- Retina displays capture at 2× — a 1512×949 window yields a 3024×1898 png.

## End-to-end checks against herdr — without disrupting live work

rai is a GUI client for the `herdr` daemon, which holds **real, running** agent
sessions. The cardinal rule:

> **Never split, close, or refocus another person's active agents.** Do all
> structural testing in isolated, throwaway workspaces created with `--no-focus`,
> and clean them up when done.

Inspecting state is always safe — the snapshot is read-only, and its array order
is the canonical (sidebar) order, so don't re-sort by `number`:

```sh
herdr api snapshot           # full ordered workspaces → tabs → panes + statuses
```

Throwaway-workspace pattern (this is how the reopen-tab and slot-ordering
behavior were verified live):

```sh
# create WITHOUT stealing focus, then find the new workspace id by diffing
before=$(herdr api snapshot | jq -r '.result.snapshot.workspaces[].workspace_id')
herdr workspace create --cwd /tmp --no-focus
after=$(herdr api snapshot | jq -r '.result.snapshot.workspaces[].workspace_id')
ws=$(comm -13 <(echo "$before" | sort) <(echo "$after" | sort))

# …exercise tab/pane/agent commands in "$ws", re-inspect via `herdr api snapshot`…

herdr workspace close "$ws"  # ALWAYS clean up
```

Rules that keep tests non-disruptive and correct:

- Pass `--no-focus` on every `create` / `agent start` so the user's view never
  jumps.
- Since herdr 0.7.5, `agent start` only wraps a **recognized** agent kind
  (`--kind claude|codex|…`) inside an **existing** pane sitting at a shell
  prompt — the old dummy-agent mode (`agent start test --tab … -- /bin/sh`)
  is gone. For structure tests, drive the pane's shell directly with
  `pane send-text` / `pane send-keys` instead; a plain shell never counts as
  a tracked agent anyway, so it proved nothing about agent status.
- A freshly created tab (and a new workspace's root) already has a
  **default shell pane** — that pane is your test surface.
- herdr refuses to close the **last** tab in a workspace
  (`{"code":"tab_close_failed"}`).
- Close every throwaway workspace when finished.

### herdr command quick reference

| command | purpose |
| --- | --- |
| `herdr api snapshot` | full runtime state (workspaces/tabs/panes/agents), canonical order |
| `herdr workspace create [--cwd P] [--focus\|--no-focus]` | new workspace (response includes the `root_pane`) |
| `herdr tab create --workspace <id> [--cwd P] [--label L] [--no-focus]` | new tab (seeds one default pane) |
| `herdr agent start <name> --kind <kind> --pane <id> [-- <agent args…>]` | start a recognized agent in an existing shell pane |
| `herdr pane send-text <paneID> <text>` | type text into a pane |
| `herdr pane send-keys <paneID> <key>` | send a key (`Enter`, `Escape`, `C-c`, …) |
| `herdr pane split <paneID> --direction <right\|down>` / `pane close <paneID>` | split / close a pane |
| `herdr workspace close <id>` / `herdr tab close <id>` | tear down |

The `poc/herdr_client.py` client (see the README) exercises the same socket in
Python if you'd rather not shell out.

### Isolated herdr lab (closed-tab e2e)

`scripts/herdr-lab.sh` runs a **named herdr session** (`railab`) with its own
state and sockets — the default herd and its persisted `session.json` are
never touched — plus a fake `claude` on the server's PATH that records its
argv and keeps a claude-named process alive, so agent detection works without
burning real agent sessions:

```sh
scripts/herdr-lab.sh start
HERDR_SOCKET_PATH=$(scripts/herdr-lab.sh socket) poc/closed_tab_e2e.py
scripts/herdr-lab.sh stop
```

`poc/closed_tab_e2e.py` replays the exact CLI sequences RaiModel issues for
closing and reopening tabs — structural contract (labels, rename, splits,
zoom, dead-workspace errors), the shell-readiness race, the single-pane agent
reopen (the herdr ≥0.7.5 `agent start --tab` regression), the multi-pane
shape rebuild, and the last-tab-of-space reopen (closing a workspace's only
tab closes the space; reopen recreates it under its label and adopts its
default tab). Exit code 0 means all checks passed.

rai launches an agent one of two ways, and the lab exercises both:
- **Fresh launch, no resume** (`launchAgent`, `launchAgentFromBridge`): herdr's
  own `agent start <name> --kind <kind> --pane <id>` — it waits for the pane's
  shell prompt and the agent's own readiness internally, so no delay is
  guessed and there's no window to lose text in (verified 5/5 at 0ms). rai
  declares no minimum herdr version, so a rejected `--kind`/`--pane` (pre-0.7.5
  herdr; the pane is left at a clean shell prompt either way) falls back to
  typing the bare launch command directly, same as the resume path below.
- **Resume, with a `first || fallback` shell chain** (reopen, shape rebuild):
  `agent start`'s trailing args exec straight into the agent binary, so they
  can't carry `||`. These type the resume command with `pane run`, then poll
  for the agent to appear and retype once if it didn't land — a fixed delay
  before a single blind attempt can guess wrong on a slow shell startup and
  silently drop the whole line.
