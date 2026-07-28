# Collie → rai iOS: feature-gap audit

Collie (the herdr-plugin phone PWA, surveyed at v0.14.2) solves the same
problem as rai's iOS companion. This is what each side has that the other
lacks, and a value-ordered backlog of what rai should absorb.

Audited 2026-07-28 against rai iOS build 10.

## Where rai is already ahead

- **Real terminal, live-streamed** — SwiftTerm fed by `terminal session
  observe` frames. Collie polls `pane read` text every 1.5–12 s and
  explicitly parked live streaming (its ARCHITECTURE.md).
- **Native APNs push** with Approve / Deny / Reply actions on the
  notification itself — collie removed one-tap replies (approving blind)
  and its web-push can only deep-link.
- **Agent launcher** (Claude / Codex / Terminal + directory) — collie has
  none; a new tab hands you a bare shell.
- **Direct keyboard → pty**, photo-to-agent, remote-scrollback seeding
  with in-terminal search, QR/deep-link pairing independent of Tailscale
  identity.

## What collie has that rai iOS lacks

### Tier 1 — changes the daily experience

1. **Structured prompt blocks.** Collie parses Claude's dialogs out of the
   pane text and renders native controls: single-choice permission/trust/
   plan prompts as buttons with digit badges, multiSelect checkboxes with a
   verified pointer-walk submit, multi-question wizards with a stepper, the
   preview-variant AskUserQuestion with attachable notes — all behind a
   race guard (fresh read + revision + region-signature check before any
   keystroke) and a raw-terminal escape hatch. This is the single biggest
   phone-UX gap: on rai you answer a permission prompt by reading a TUI at
   80 columns and typing digits. rai has an advantage collie lacks — we
   hold a live SwiftTerm grid, so detection can read cells instead of
   re-parsing ANSI text.
2. **Notification intelligence** (Mac-side work): a debounce before
   pushing (collie waits 30 s — handled at your desk means the phone never
   buzzes), automatic retraction when the agent resolves or the pane
   closes, coalescing into one summary ("3 agents need you"), per-kind
   toggles (needs-input / finished), and DND/snooze presets settable from
   the phone. rai currently pushes immediately, never retracts, never
   coalesces, and has no phone-side notification preferences.
3. **Composer accelerators**: quick-reply grid (yes / no / continue /
   commit-and-push / retry / skip), agent-aware slash-command palette
   (collie ships 49 Claude + 33 Codex entries with dangerous-command
   two-tap), and a key queue with combinable Shift/Ctrl/Alt modifiers that
   can lock and send chords as one call.

### Tier 2 — solid wins

4. **Agent statusline surfaced** (model · ctx% · cwd · branch · tokens):
   collie strips Claude's statusline from the mirror and pins it above the
   composer. We already stream those rows; we render them as pixels.
5. ~~**Load older scrollback**~~ — resolved without paging: the seed now
   carries herdr's full ~1000-line history into a 2000-line SwiftTerm
   buffer (build 13). Paging UI dropped by decision; going deeper than
   that is a herdr history-size question, not an app one.
6. **Triage grouping with counts**: Needs you / Working / Idle·done as
   first-class groups (blocked always first), worst-status dots on space
   headers, per-session counts. rai has a Needs-you section, then a flat
   workspace list.
7. **Destructive-input confirm**: two-tap on `rm -r`, `sudo`, forced
   pushes, `dd`, redirects to system paths.
8. **In-app transition toasts** ("claude needs you · demo") while the app
   is open, suppressed for the pane being viewed.
9. **Display prefs**: wrap toggle, font-size stepper, per-pane, persisted.
10. **Claude `/rename` name sniffing** for pane display names.

### Tier 3 — worth stealing eventually

11. **Connection-cause diagnosis**: one health clock driving a single
    banner that distinguishes "herdr is down on the host" from "can't
    reach the bridge", with retry. rai surfaces raw URLError strings.
12. **Read-only device tier + audit log**: collie's device allowlist
    fails closed to read-only, and every write action lands in a 0600
    JSONL audit log. rai's single token grants full control, unlogged.
13. **Send-echo confirmation**: "You sent: …" pending preview until the
    mirror echoes it, and typed-but-not-submitted partial-failure copy.
14. **Idle lock** (30 min, timestamp-based) as a privacy courtesy.
15. **Draft take-over**: a desktop-typed draft is shown read-only with an
    explicit Take-over, instead of silently interleaving two keyboards.

### Not applicable / already covered natively

PWA installability, service-worker update dances, ETag/304 + gzip polling
economics, boot splash — native app + TestFlight + streaming make these
moot. Multi-session switching is already tracked (parity backlog #3).

## Suggested build order for rai iOS

1. Structured prompt blocks for Claude dialogs (Tier 1.1) — start with the
   single-choice permission prompt, detected from the live grid.
2. Notification debounce + retraction + coalescing on the Mac, per-kind
   prefs + snooze over the bridge (Tier 1.2).
3. Quick replies + slash palette (Tier 1.3, client-only).
4. Statusline strip + load-older-scrollback (Tier 2.4–2.5).
5. Triage grouping rework of MonitorView (Tier 2.6).
