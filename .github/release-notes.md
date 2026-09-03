Native macOS client for [herdr](https://herdr.dev). Universal binary (Apple Silicon + Intel), macOS 14+.

### New in this release

- **Answer Claude permission prompts from the phone.** The Claude hook now
  waits (up to a configurable 5–60 s, default 45 s) for an Allow/Deny from
  Rai Remote when you are away from the Mac, delivered as a time-sensitive
  push with Approve/Deny actions. No decision, or you back at the Mac, and
  Claude draws its normal dialog. Settings → Integrations has the toggle and
  the hold time; the hooks installer writes the matching timeout.
- **Time-sensitive "needs you" pushes.** Blocked-agent pushes break through
  Focus modes; "finished" pushes stay ordinary.
- **Phone-side notification preferences.** Per device: kinds, snooze
  (15 min / 1 h / until 8:00), and a daily do-not-disturb window, enforced on
  the Mac before anything is sent and shown in the Doctor.
- **Stable bridge error codes.** `error` / `authFailed` carry a code the
  phone maps to the right action (retry, Pair Again, update).
- **APNs key as a validated file.** The `.p8` lives in
  `~/Library/Application Support/Rai/apns-key.p8` (0600), migrated once from
  the Keychain item, validated on Save, and named in the Doctor.
- **First frame on attach.** A phone attaching to an alt-screen agent pane
  gets the visible grid immediately instead of waiting for the next repaint.
- **Typing latency, measured.** `rai-bench --latency` drives a real keystroke
  through the terminal and times it to the display update; the daemon echo
  measures median ~4 ms with a p90 of ~22 ms (bimodal: one keystroke in ten
  waits a daemon tick). Predictive local echo can now cover that tail, but it
  ships **off by default** (Settings → "Predict local typing") because a prompt
  that silently disables echo can show one typed character before retraction.
  Remote-herd prediction is unchanged and gains the same lifecycle guards.

Ships with **Rai Remote build 33** (TestFlight): structured Claude prompt
controls (AskUserQuestion wizard, trust dialogs), Approve/Deny decisions,
transcript history for hook-enabled panes, a statusline strip, notification
preferences, and a password-prompt guard on every typed send.

Bridge protocol stays 6 (all additions are optional fields); existing
pairings keep working.

### Install

```sh
brew install --cask yogevkr/tap/rai
```

Or download the `.dmg` below, open it, and drag **Rai** into **Applications**.

Then open rai — it starts the herdr server itself if one is not running.

Prefer to build it yourself? `git clone` and run `./scripts/bundle.sh`.
