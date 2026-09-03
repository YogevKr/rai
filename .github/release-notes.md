Native macOS client for [herdr](https://herdr.dev). Universal binary (Apple Silicon + Intel), macOS 14+.

### New in this release

- **Pair each phone with a short code.** Settings → iPhone shows an
  8-character code that expires in 10 minutes. Each phone gets its own
  credential; revoke one without touching the others. Every write from a
  phone lands in an audit log, one JSON line each, opened from Settings →
  iPhone. **Existing phones must pair again** (bridge protocol 6): update
  Rai Remote to build 32, then scan the new code.
- **The real question rides the push.** Install the Claude Code hooks from
  Settings → Integrations (it previews the change and keeps a backup of
  `~/.claude/settings.json`). A blocked pane's sidebar row then shows the
  pending tool ("Bash: touch …"), and the Mac notification and the phone
  push say what Claude is asking instead of only which pane.
- **Smarter pushes.** Several agents blocking at once become one
  "N agents need you" push that opens the triage list; pushes group by
  workspace on the phone; a pane you handle at the desk has its phone
  notification retracted; Settings → iPhone gains a test push and a
  read-only Doctor that names the fix for each finding.
- **Rai Remote build 32.** Permission dialogs show tappable numbered
  buttons again. A Triage groups toggle in the connection menu turns the
  groups and the pulse line off for a plain space list. The last herd shows
  at launch with a last-seen stamp, and a dropped connection says why
  ("Rai on the Mac isn't listening", "Can't find the Mac on this network")
  with the right action.

### Fixed in this release

- **Tab titles on the phone no longer show a bare number.** herdr auto-names
  a fresh tab after its own number ("3") until it gets a real title. The Mac
  already knew to treat that as no title and fall back to the pane's terminal
  title; the phone didn't, so an auto-named tab showed the literal digit
  instead of the running agent's task. Both platforms now fall back the same
  way.

### Install

```sh
brew install --cask yogevkr/tap/rai
```

Or download the `.dmg` below, open it, and drag **Rai** into **Applications**.

Then open rai — it starts the herdr server itself if one is not running.

Prefer to build it yourself? `git clone` and run `./scripts/bundle.sh`.
