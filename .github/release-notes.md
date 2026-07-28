Native macOS client for [herdr](https://herdr.dev). Universal binary (Apple Silicon + Intel), macOS 14+.

### New in this release

- **Reverts v0.1.12's terminal‑selection changes.** Those changes assumed the
  pane terminal had its own scrollback, but rai renders panes through herdr's
  full‑screen attach (the scrollback lives in herdr), so the selection
  auto‑scroll had nothing local to move and the wheel change interfered with
  scrolling while text was selected. Reverted to the prior, working behavior.
  Proper selection‑scrolling needs a deeper terminal change and is in progress.

### Install

1. Download the `.dmg` below, open it, and drag **Rai** into **Applications**.
2. rai isn't notarized yet (no paid Apple Developer account), so on first launch
   macOS Gatekeeper will block it. Do **one** of:
   - **Right-click** `Rai.app` → **Open** → **Open**, or
   - run `xattr -dr com.apple.quarantine /Applications/Rai.app` and launch normally.
3. Make sure a herdr server is running (`herdr server`), then open rai.

Prefer to build it yourself? `git clone` and run `./scripts/bundle.sh`.
