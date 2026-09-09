# Testing & end-to-end verification

How to build, run, screenshot, and end-to-end verify rai against a live `herdr`
daemon — without disrupting anyone's running agents.

For Herdr 0.9 work, follow the [isolated app test contract](herdr-0.9-e2e.md).
Every feature requires isolated macOS and iOS app end-to-end results before completion.
The [integrated checkpoint](herdr-09-integrated-validation.md) records combined builds, UI findings, and pending corrections.
The development bundle and named Herdr lab below do not provide complete app data isolation.

## Build & run a dev build

`scripts/bundle.sh` compiles an optimized build and installs `Rai Dev.app` in `/Applications`.
It falls back to `~/Applications` when necessary.
Development builds use `gr.krig.rai.dev`, separate preferences, and a stable signing identity.
They do not replace `Rai.app` or install release updates.

```sh
./scripts/bundle.sh          # arm64 dev build → /Applications/Rai Dev.app
open -a "Rai Dev"
```

Env overrides:

| var | effect |
| --- | --- |
| `RAI_VERSION` | `CFBundleShortVersionString` (default `0.1.0`) |
| `RAI_UNIVERSAL=1` | universal arm64 + x86_64 binary (used by the release workflow) |
| `RAI_APP_DEST` | install into this dir instead of `/Applications` |
| `RAI_BUILD_CHANNEL` | `development` by default; `release` builds `Rai.app` with `gr.krig.rai`. |
| `RAI_SIGN_IDENTITY` | Stable signing identity. Development defaults to `rai-dev-signing`. Release requires an explicit Developer ID Application identity. Missing identities stop the build before installation. |
| `RAI_PAIRING_CODE_FILE` | Test harness only: writes the current pairing code to an owner-only file. Unset in normal use. Pair through `SIMCTL_CHILD_RAI_PAIR_URL="rai://pair?host=localhost&port=<RAI_BRIDGE_PORT>&code=<code>"`. Verify separate app data, credentials, and bridge targets first. A changed `HOME` does not isolate Application Support. Never delete shared `bridge-audit.jsonl` or `hooks.sock` files as test cleanup. |

For a quick loop without bundling, `swift run rai` runs straight from the package.

For development bundles, use an existing stable identity or create a Code Signing certificate in Keychain Access.
Use the name `rai-dev-signing`, or set `RAI_SIGN_IDENTITY` to its full name.
Keep that identity across rebuilds. Never alternate signing identities for one bundle ID.
Release builds verify the publisher requirement used by the updater before installation.
CI stops when the release certificate is unavailable; it never publishes an ad-hoc substitute.

Development and release apps still share Herdr and Rai's existing Application Support files.
Do not run both integrations against the same keyboard during device tests.

## Herdr 0.9 app lab

The lab channel uses a unique bundle identity and refuses incomplete launch configuration.
Prepare a run with a verified Herdr binary:

```sh
python3 scripts/app-lab.py prepare --herdr /path/to/verified/herdr
```

The command prints `root`, `lab_id`, `bundle_id`, and `bridge_port`.
Use those returned values to build and launch:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  RAI_BUILD_CHANNEL=lab RAI_LAB_ID=<lab_id> RAI_APP_DEST=<root>/apps \
  ./scripts/bundle.sh
python3 scripts/app-lab.py launch --root <root> --app '<root>/apps/Rai Lab <lab_id>.app'
```

The lab stores its launch manifest, process IDs, logs, private binary, sockets, and application data under `root`.
The unique bundle identity separates preferences. `RAI_DATA_ROOT` separates app-owned support files and Claude history.
The launcher supplies private Herdr configuration, state, cache, hook routing, shell startup files, and Git configuration.
It also supplies private temporary, Claude, and Codex directories to its child processes.
Before starting Herdr, the launcher runs the app's `--validate-lab` check against the complete launch environment.
Lab apps skip legacy APNs key migration, Bonjour advertisement, and automatic Tailscale Serve changes.
Native Claude and Codex integration controls use their supported directory overrides.
Other native integrations require a disposable test account. The lab blocks those controls until their targets can be isolated.
Lab hook previews and writes reject settings or script paths outside the lab, including paths through symbolic links.
The lab blocks SSH discovery, session listing, and tunnels until a disposable SSH account and configuration are available.
An owned `.rai-lab-ssh.json` fixture enables only its declared SSH aliases and loopback endpoint.
Set `RAI_MACHINE_E2E_ROOT` to that lab root when running `MachineTransportTests`.
These tests require live detached Herdr sessions and validate distinct machines with duplicate pane identifiers.
Keep physical notification tests separate, using dedicated test credentials and registrations.

The launcher refuses existing process records. Inspect recorded processes before reusing a run.
Stop only processes whose executable and ownership marker match that run. Preserve logs before cleanup.

Use a dedicated simulator for the phone lab. Build with a separate `PRODUCT_BUNDLE_IDENTIFIER`.
Simulator pairing requires signing: pass `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` to the simulator build.
An unsigned simulator app can fail Keychain writes with error `-34018`.
Keep the test bundle identifier separate from `com.whetstone.rai.ios`.

The lab launcher establishes test targets. It does not count as a feature end-to-end pass.
Follow the [feature scenarios and evidence rules](herdr-0.9-e2e.md) for app UI validation.

### Missing Herdr on a new Mac

Create the negative-test lab with `python3 scripts/app-lab.py prepare --without-herdr`.
Build and launch its app with the same lab commands above.
This manifest permits an absent private executable and does not start a server.
All path, identity, and port checks still apply.
The launcher verifies that the app owns its bridge listener before reporting success.
Servers that Rai starts after Retry receive `herdr-<pid>.json` ownership records inside the lab.
Use these records, the ownership marker, and the live executable path before stopping a test server.

Verify the installation screen appears without a connection spinner or repeated error alerts.
Select Retry before installation and confirm the screen remains usable.
Copy the verified Herdr binary to this lab's `bin/herdr` and grant owner execute permission.
Select Retry again without restarting Rai. Verify the default server starts and a workspace opens.
Pair the isolated phone and verify the missing-server diagnosis clears after recovery.
Keep UI evidence for both platforms. Unit tests alone do not complete this scenario.

Run regression tests with `swift test --filter HerdrInstallationTests` using the Xcode developer directory.

## Agent startup prompts

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter AgentLaunchReadinessTests
```

Claude's folder-trust prompt means the agent launched and needs input.
Rai accepts a readiness rejection only when the requested pane reports the expected agent as blocked.
The tests cover readiness timeouts, missing state, wrong panes, wrong agents, and actual launch failures.
Rai leaves the startup decision to the user and does not send a replacement launch command.

## Full Disk Access guidance

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter FullDiskAccessGuidanceTests
```

The tests check actual file access errors, wrapped errors, and unrelated failures. No startup action requests this guidance.
They never read protected files or change macOS permissions.

For a manual check, launch the isolated lab bundle with fresh preferences.
Verify that startup, installation, new windows, and restarts show no Full Disk Access dialog.
Trigger a denied configuration or hook-settings operation. Verify that its error offers **File Access Help…**.
Successful operations and unrelated errors must not offer this button. Select the button to open the guide.
Verify that the Full Disk Access dialog explains its optional scope and offers **Open System Settings** and **Not Now**.
Check light and dark appearance in a bundle containing `Rai.icns`. The sheet must show Rai’s icon without a separate Dock item.
Dismiss it, open another window, and restart. The dialog must remain closed.
Open **Settings → Herdr Server → Mac Privacy → Review Full Disk Access…** to show it again.
Verify that **Open System Settings** opens Privacy & Security → Full Disk Access, without changing any grant.
Granting access remains a separate user action in macOS. Follow its quit-and-reopen request when testing a grant.

## Codex Micro permissions

Grant Input Monitoring separately to `Rai.app` and `Rai Dev.app` when using their keyboard integration.
If a previous development build replaced `Rai.app`, remove its old Input Monitoring entry and add the installed release app.
Quit and reopen that app after granting permission. This repairs the existing certificate mismatch once.

Settings → Codex Micro reports access failures at startup and after reconnection.
Use **Open Input Monitoring** for permission failures, then follow the macOS restart request.
Use **Retry connection** to restart device monitoring without losing bindings or the enabled setting.

```sh
python3 Tests/BuildScripts/test_bundle.py
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter 'MicroStatusTests|CodexMicroTests|AppUpdateTests'
```

The bundle tests use temporary apps and fake build/signing tools. They never replace the installed Rai app.
They verify separate development identity, required signing, publisher rejection, and preservation of the installed release on failure.
The Swift tests verify permission recovery state, saved bindings, and disabled release updates in development builds.

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

## Native Herdr endpoint tests

Run endpoint wire, deadline, cancellation, surface, paste, keyboard, and input identity tests with the Xcode toolchain:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter 'HerdrEndpointTests|HerdrScrollTransportTests|EndpointKeyboardTests|EndpointBridgeHostTests|EndpointLinkTests'
```

These tests use temporary Unix socket fixtures. They do not control the installed Herdr server.
Set `RAI_ENDPOINT_TEST_ROOT` to an owned app lab to include the live native handshake and surface check.
The live test verifies the lab ownership marker before connecting.

Additional Mac windows and the phone Workspace View use native endpoint transport.
Test history page controls, live-output recovery, and scrollbar expiry without terminal geometry changes.
Select Light, Dark, and System after each explicit mode. Change the simulator appearance while Workspace View remains open.
Verify Always and Auto with one and two panes. Compare pane reads before and after border changes.
Set different appearance and border choices in two Mac windows. Verify each existing window retains its choices.
Restart the isolated app, open another window, and verify the last saved choices become its defaults.
Restart the isolated Mac host while Workspace View remains open. Verify automatic recovery and input with new view identity.
Background and restore the phone app. Close Workspace View, restart the host, and verify no new endpoint opens.
Test image replacement beside another image, clipped history recovery, rotation, deletion, and image inspection.
The Mac and phone share image cache and SwiftTerm replacement regression tests.
Test configured commands with captured targets. Reload configuration while the command list remains open and verify stale-command rejection.
Test release notes on both platforms. Verify popup input reaches only the active popup terminal.
Views of one Herdr pane share history position. Validate touch gestures separately from menu actions.
The primary Mac window and phone observation view retain their previous terminal paths.
Phone endpoint tests cover request identity, sizing, navigation, queue limits, failed writes, and closure races.
Phone text tests cover stable capture, implicit links, OSC 8 links, and rejected remote file paths.
Verify touch selection, Copy, and browser navigation in both phone terminal views.
During output, capture text and confirm later output cannot change the capture or selected text.
Test tab creation, splits, directional focus, paste boundaries, application cursor keys, Kitty keys, reconnect, and window closure.
Use separate app windows and record each input marker's target pane.
Record app hashes and pane snapshots before removing temporary test panes.
Full unit gates do not replace the isolated app scenarios in `herdr-0.9-e2e.md`.

## iOS connections and terminal retention

Generate the iOS project, then run the tests on an isolated simulator:

```sh
xcodegen generate --spec ios/project.yml
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project ios/rai-ios.xcodeproj -scheme rai-ios \
  -destination 'platform=iOS Simulator,id=<simulator-id>' \
  -derivedDataPath /tmp/rai-ios-network-tests test
```

`BridgeNetworkTests` covers stalled authentication, missing pongs, network changes, late errors, and composed-line queue behavior.
`BridgeSocketIntegrationTests` uses a loopback WebSocket server with delayed authentication and a dropped connection.
It checks ping handling, conditional history replies, and raw-key replay prevention.
`ScrollbackRefreshTests` covers traffic pacing, conditional replies, and cancellation when the user leaves a pane.
`TerminalViewCacheTests` covers cached cells, scroll positions, memory limits, context isolation, and nested horizontal offsets.
It checks text positions after history trimming and terminal deallocation after cache removal.
Its SwiftUI navigation test records a screenshot before any reply reaches the restored terminal.
`PromptDetectionTests` rejects cached permission controls until a full screen frame arrives.
`FullFrameRepaintTests` covers full frames that match the retained screen, changed text, attributes, cursor, grid size, and the ignored preview frame.
`ConnectionBannerStateTests` covers the three-second delay, recovery, repeated retries, and immediate pairing repair.
It also checks banner height with a long hostname at normal and accessibility text sizes, and records screenshots.
`BridgeErrorPolicyTests` checks that legacy action errors preserve a healthy connection while missing-herd errors remain visible.
`OfflineResilienceTests` checks that disconnected rows remain stale through authentication until a fresh snapshot arrives.
These tests use synthetic content and do not connect to Herdr or change system network settings.

Run the shared protocol and Mac bridge checks with `swift test`.

Herdr management regression tests cover capability checks, target identity, audit records, and phone failure recovery.
Run `swift test --filter 'HerdrManagementTests|HerdrManagementAppTests|BridgeAudit'` for the focused Mac gate.
The simulator suite includes `HerdrManagementBridgeTests` for stale confirmation, result correlation, socket loss, and audit rejection.
Use an owned lab server for app update and handoff checks. Compare shell and agent process IDs before and after handoff.
See [Herdr 0.9 evidence](herdr-0.9-e2e.md) for current isolated app results and remaining checks.

## Application updates

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter 'AppReleaseTests|AppUpdate|AppTerminationTests'
```

These tests cover numeric version order, release assets, skipped versions, retry, duplicate actions, and opaque dialog rendering.
The popup consumes Command-W and Command-Shift-W. Tests check that both shortcuts dismiss it without reaching a terminal.
Manual checks join an active background request and keep their visible result, including skipped releases and errors.
Installation tests use temporary app folders. They check replacement, rollback, retained backups, and signature rejection.
They do not replace `/Applications/Rai.app` or stop Herdr.

Set `RAI_UPDATE_DIALOG_SNAPSHOT` to a PNG path to save the dialog render during `AppUpdateTests`.
The optional signature probe uses the downloaded official 0.1.48 ZIP and its extracted app:

```sh
RAI_UPDATE_ARCHIVE_PROBE=/path/to/Rai-0.1.48-macos.zip \
RAI_UPDATE_APP_PROBE=/path/to/unpacked/Rai.app \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter AppUpdateTests.testOfficialReleaseArchiveAndSignature
```

`rai-updater` runs outside Rai's app process. It verifies the candidate before reporting readiness and again after Rai exits.
It waits up to two minutes for normal shutdown. It never stops the Herdr server.
Rai schedules update shutdown on the main run loop, after the update task returns.
This lets the delegate's cleanup task run inside AppKit's termination loop. Normal Quit and system shutdown keep their existing behavior.
`AppTerminationTests` checks that the shutdown callback runs on the main thread, outside the calling task.
The installer retains the previous app and reports errors instead of deleting the backup.
`scripts/bundle.sh` includes and signs the helper before signing the outer app.

Release metadata and archive hashes come from the [GitHub Releases API](https://docs.github.com/en/rest/releases/releases).
Signature checks use Apple's [Code Signing Services](https://developer.apple.com/documentation/security/code-signing-services).
Current release archives contain no symbolic links. The installer rejects archives with symbolic links before extraction.

## Hidden terminal streams

Rai disconnects a display client after its view stays outside a window or hidden for one second.
It keeps the cached view and reconnects when the view becomes visible.
Cached views reconnect immediately, so the first keys after a tab switch reach the client.
Rai enables raw PTY input before accepting keys. Control keys then survive the client's connection handshake.
The Herdr server keeps the pane process running. Brief view transfers retain the existing client.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter TerminalVisibilityTests
```

These tests use local PTYs. They check visibility, cached scrollback, input after reconnect, retries, eviction, and child process cleanup.
The control-key test delays client setup and checks that Ctrl-C, Backspace, Ctrl-V, text, and Return arrive unchanged.

An isolated Herdr 0.8.0 test on 2026-09-06 used eight shell processes with a 100 ms output interval.
Each CPU sample lasted ten seconds. Percentages refer to one CPU core.

| Display clients | Server CPU |
| --- | ---: |
| Eight connected | 5.2% |
| One connected, seven hidden | 2.7% |
| Eight reconnected | 8.2% |

All eight process IDs stayed unchanged, and output continued while seven views were hidden.
The hidden views kept their buffers. Their clients exited without leaving child processes, and reconnected views received current output.
These samples verify this workload. They do not predict CPU use in a live herd.

## Typing latency benchmark

The Mac terminal parses queued output in chunks of at most 16 KB.
It returns to the event loop between chunks and paces their display updates.
The PTY reader waits for each read to finish parsing before delivering another read.
This keeps pending transport output within one 128 KB read. Keyboard writes use a separate path.
Small keyboard echoes retain the immediate display path.
Stopping or replacing a terminal releases blocked reads and discards output from the old process.

Run the output and transport regression tests:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter TerminalOutputTests
```

These tests check event-loop progress, byte order, Unicode, synchronized output, cancellation, keyboard delivery, and PTY resizing.

Frame pacing delays display updates, but it does not delay parsing reads of 16 KB or less.
The reader acknowledges these reads immediately. Keyboard echoes can then follow background output without waiting for another frame.
A regression test checks parsing, read acknowledgement, and echo order without advancing the event loop.

Measure the production Rai view and a real, isolated PTY:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  RAI_TYPING_LATENCY_PROBE=1 swift test --filter TypingLatencyProbeTests
```

The probe tests small echoes, 1 KB echoes, and typing during continuous output.
It sends events directly to its own view. It never types into a Herdr pane.
Each scenario records 60 samples after ten warmup keys. Predictive echo stays disabled.
Timing stops at the display-update callback, before physical screen presentation.

On 2026-09-06, the streaming median fell from 108.1 ms to 17.3 ms after removing the read delay.
The streaming p90 fell from 182.6 ms to 23.8 ms. These debug-build results describe this workload only.
Small-echo medians stayed below 1 ms. Large-echo medians stayed near 21 ms.

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
risk. After a pause longer than 300 ms, the next key waits for its echo, local
and remote. The harness commands above measure the opt-in rendering paths.

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
