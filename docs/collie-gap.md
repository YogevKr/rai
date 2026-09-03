# Collie → rai: feature-gap audit

Collie (https://colliepwa.dev, github.com/AltanS/collie) solves the same
problem as rai's iOS companion: steer a herd of terminal agents from a phone.
This is what each side has that the other lacks, and a value-ordered backlog
of what rai should absorb.

- First audited 2026-07-28 against Collie **0.14.2** (a herdr plugin PWA) and
  rai iOS build 10.
- Re-audited **2026-09-02** against Collie **1.2.0** and rai iOS build 28.
  Collie 1.x is a different product: a standalone binary with herdr, tmux and
  zellij drivers, device pairing, packs, voice input and six UI languages.

## Where rai is ahead

- **Real terminal, live-streamed** — SwiftTerm fed by `terminal session
  observe` frames. Collie polls `pane read` text every 1.5–12 s and has an ADR
  (0008) committing to never run a terminal emulator.
- **Native APNs push** with Approve / Deny / Reply actions on the notification
  itself, and a presence gate: the phone is pushed only after you leave the
  Mac. Collie's web push can only deep-link.
- **Agent launcher** (Claude / Codex / Terminal + directory) — Collie's new
  tab hands you a bare shell.
- **Direct keyboard → pty**, photo-to-agent, remote-scrollback seeding with
  in-terminal search, QR/deep-link pairing independent of Tailscale identity,
  session follow from the phone.

## July list — status

Closed since the July audit: single-choice permission/trust prompt buttons
with a signature race guard; quick replies + agent-aware slash palette with
two-tap danger; destructive-input confirm; push presence gate; Mac and phone
notification retraction; push coalescing and grouping; triage groups with counts
and a filter pulse line (Nightwatch); session follow.

Still open from July: AskUserQuestion / multi-select / plan / wizard prompt
blocks; per-kind toggles; DND/snooze; statusline strip; connection-cause
diagnosis; read-only tier + audit log; draft take-over; per-pane display prefs.

## New in Collie 1.x worth borrowing (ranked for rai)

1. **Verified send.** A phone reply writes text + CR in one blind write
   (`ios/rai-ios/PaneTerminalView.swift`). Collie types the text unsubmitted,
   reads the grid until it shows on the input line, then presses Enter — its
   issue #34 was a blind Enter that approved a highlighted "Yes" on a
   permission dialog. rai holds a live grid on the phone, so the check is
   cheap. Carry two facts: Claude collapses pastes over ~400 chars into a
   `[Pasted text #N]` token (Collie ADR 0010), and Codex keeps only 1024
   chars of one send (`[Pasted Content N chars]`).
2. **Agent hooks as the source of truth — LANDED on Mac (2026-09-02).** Rai
   installs Claude hooks so a
   pane reports its name, status and session ref ("beacons"). Collie admits
   its push body cannot carry the question because parsing is client-side
   over the screen. rai can go further: a Claude Code `PermissionRequest` /
   `PreToolUse` hook posting tool name, tool input, `session_id` and
   `HERDR_PANE_ID` to the Mac gives the push a real body ("Run `bun run
   build` in ~/src/collie?") and gives AskUserQuestion its options as data.
   Grid parsing stays as the fallback and as the race guard. The Mac receiver,
   notification bodies, bridge field, and sidebar text now ship. Structured
   phone prompt controls remain in wave 2.
3. **History from the transcript, not the screen.** Claude runs on the
   alternate screen, so the grid has no scrollback ring. Collie reads the
   agent's own JSONL transcript (`bridge/journal/`) and offers
   find-in-history and jump-to-user-turn. rai seeds ~1000 lines of herdr
   history; a transcript view would serve Mac and phone alike.
4. **Password prompt recognition changes copy, never keys** (ADR 0017).
   Collie matches `[sudo] password for`, `'s password:`, `Enter passphrase`
   and says "Collie will not type"; it also stops storing the draft. rai's
   outbox is memory-only, but the notification Reply action and quick
   replies would type into a sudo prompt blind.
5. **Per-device credentials and audit.** ✅ Rai now uses an 8-character code,
   a 10-minute limit, five attempts, hashed device credentials, live revoke,
   and a `0600` JSONL write audit. **LAN TLS remains open.** The LAN pairing
   URL still uses plain `ws://`, so pane content crosses the LAN without TLS.
   The Tailscale path uses `wss://` through `tailscale serve`.
6. **Doctor and push-test. ✅ Landed 2026-09-02.** `collie doctor` is one read-only pass over the
   traps that fail silently, each finding naming the fix; `collie push-test`
   proves delivery. rai already fixed a silent missing-APNs-key drop.
7. ✅ **Cached last screen on cold boot**, stamped "last seen HH:MM", plus a
   ticking "synced Ns ago" freshness promise (ADR 0031). Landed on iOS.
8. **Operator config files.** `commands.toml`, `keys.toml`,
   `quick-replies.toml`, live-reloaded, with a `scope` so rows replace the
   shipped catalog on matching panes (ADR 0018). rai hardcodes both catalogs
   in `Composer.swift`.
9. ◐ **Stable error codes from the bridge.** The phone now maps transport,
   TLS, pairing, and missing-herdr failures. Stable Mac codes remain wave 2.
10. **Push grouping. ✅ Landed 2026-09-02.** Collie batches simultaneous blocks into one summary.
    APNs `thread-id` per workspace + `summary-arg` give this natively; a
    background push can wake the app to remove a delivered notification once
    the Mac handles it.

### One design disagreement

Opening a pane on the phone calls select with focus-in-herdr
(`Sources/RaiApp/RaiBridgeServer.swift`, `selectPane`), so browsing from the
phone moves the Mac's terminal. Collie ADR 0031: moving the operator's
terminal is a named tap ("Show in terminal"), never a side effect of
navigation. A choice to make on purpose; not scheduled.

### Leave for now

tmux/zellij drivers, packs (rai's Mac hub + SSH remotes cover multi-host),
six languages, custom typefaces, in-app speech-to-text (iOS dictation works
in the compose field; Wispr on the Mac), Zen mode. The one pack idea worth
taking later: a single "All sessions" triage list.

### From the site and repo practice

- Interactive demo: the production client against mock data in the browser.
  rai analog: a fixture-driven mock bridge for screenshots and UI iteration
  (Collie's "states playground").
- Footer stamps version · commit · build date; a build stamp rides every
  response so stale clients see "new build — tap to update". The Mac app has
  no update check; an anonymous GitHub tags check + banner matches Collie's
  zero-telemetry stance.
- Security section before install; "what leaves your machine: nothing".
- Install script verifies sha256, no sudo, `update --rollback`, major-version
  consent gate.
- 34 ADRs with sentence titles and a "what would justify revisiting" section.

## Build plan (2026-09-02) — outcome (2026-09-03)

Wave 1 ran as five Codex jobs in worktrees, each reviewed with
`codex review --base main` until a round came back clean, then merged onto
main behind the full Mac and iOS test suites.

| Branch | Review rounds | Result |
| --- | --- | --- |
| device-pairing (item 5) | 2 | ✅ merged b6ac85f — codes, per-device tokens, revoke, audit log, protocol 6 |
| offline-resilience (items 7, 9 phone side) | 2 | ✅ merged 9b43b30 — cached herd, last-seen stamp, diagnosed reconnects |
| push-intelligence (items 6, 10) | 2 | ✅ merged 5b9285e — coalescing, thread grouping, retraction, Doctor, test push |
| hook-beacons (item 2, Mac half) | 4 | ✅ merged 66a7284 — hook receiver, pane correlation, question in the push; verified live against Claude 2.1.259 in an isolated herdr pane |
| guarded-send (items 1, 4) | 9 | ⛔ **not merged** — branch `codexspin/rai-guarded-send-0902-230810-o108` (last commit 27534d9, 98 iOS tests) |

Why guarded-send stayed out: every review round found a new P1 in the
send/Enter/outbox state machine (blind Enter after a rejected text write,
duplicate replay of an uncertain queued line, a stale shell/agent policy,
and finally a regression in the *unverified* default path that dropped the
300 ms settle before Enter). The branch grew to ~2 800 lines of layered
guards. Wave 2 should redesign it with a smaller contract: the unverified
path stays byte-identical to today's send; no outbox replay while any send
is uncertain; one evidence model per pane kind (agent input box vs. shell
prompt), decided from the input rows only; and a live check on a real
Claude and a real shell pane before merge. The password-prompt guard
(item 4) is small and should ship on its own first.

Wave 2 (unchanged otherwise): structured prompt blocks fed by beacons
(AskUserQuestion, plan, multi-select, and the unnumbered `hideIndexes`
dialogs) on iOS; transcript history view; operator config files;
phone-side notification prefs (per-kind, snooze) on top of protocol 6;
bridge error codes on the Mac side; statusline strip; LAN TLS.

Wave 2 Mac typing latency landed on 2026-09-03. Local panes now use safe
predictive echo after burst confirmation. TUI mode evidence disables prediction.
Resize, copy mode, and scrollback also clear it. Small focused-pane feeds draw
without SwiftTerm's frame delay. Large and repeated feeds remain frame-limited.
The bridge protocol and iOS path did not change.
