Native macOS client for [herdr](https://herdr.dev). Universal binary (Apple Silicon + Intel), macOS 14+.

### New in this release

The companion-bridge release — everything the **Rai Remote** iPhone app
(TestFlight build 15) needed from the Mac side, plus the phone features
themselves:

- **Phone input acts like keystrokes, not pastes** — companion input is
  tokenized into text runs and real herdr keys (enter, backspace, arrows,
  escape, ctrl+letter), with a settle before a submitting Enter. Fixes
  Send-not-submitting and backspace typing `^?` on zsh panes.
- **Scroll into history from the phone** — panes seed herdr's full recent
  history (~1000 lines, ANSI colors intact) into the terminal before the live
  stream starts, resilient across reconnects; agent TUIs finally have
  scrollback on the phone.
- **Native prompt buttons** — Claude's permission/trust dialogs render as
  tappable option chips on the phone, race-guarded, answered through the new
  `sendKeys` bridge message so the dialog actually hears the keypress.
- **Launcher grows a Terminal option** — a plain shell pane in any workspace
  (or a fresh one, at a chosen directory); "New workspace" agent launches now
  really create one instead of landing in whatever was focused.
- **Companion parity batch** — workspace rename/close, broadcast input,
  session summary, and background-work surfacing over the bridge.
- **Phone UX** — direct-to-pty keyboard with a dismiss toggle and drag-down,
  quick replies, an agent-aware slash-command palette, destructive-input
  confirm, Needs-you/Working triage with counts, flattened single-pane tabs,
  and app version in the connection menu.

### Install

1. Download the `.dmg` below, open it, and drag **Rai** into **Applications**.
2. rai isn't notarized yet (no paid Apple Developer account), so on first launch
   macOS Gatekeeper will block it. Do **one** of:
   - **Right-click** `Rai.app` → **Open** → **Open**, or
   - run `xattr -dr com.apple.quarantine /Applications/Rai.app` and launch normally.
3. Make sure a herdr server is running (`herdr server`), then open rai.

Prefer to build it yourself? `git clone` and run `./scripts/bundle.sh`.
