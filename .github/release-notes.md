Native macOS client for [herdr](https://herdr.dev). Universal binary (Apple Silicon + Intel), macOS 14+.

### New in this release

- **Selections stay glued to their text while you scroll** — select something,
  scroll the pane, and the highlight now moves with its content: it hides when
  its text scrolls off‑screen and comes back when you return, re‑anchoring at
  scroll speed (driven by herdr's live scroll events, ~30 ms). On panes where
  the running app owns the wheel (e.g. Claude scrolling its own view), a
  selection whose text moved away clears honestly instead of highlighting the
  wrong lines.
- **Codex Micro: the "working" key is steady blue** — no more breathing pulse
  for the herd's normal state.

### Install

1. Download the `.dmg` below, open it, and drag **Rai** into **Applications**.
2. rai isn't notarized yet (no paid Apple Developer account), so on first launch
   macOS Gatekeeper will block it. Do **one** of:
   - **Right-click** `Rai.app` → **Open** → **Open**, or
   - run `xattr -dr com.apple.quarantine /Applications/Rai.app` and launch normally.
3. Make sure a herdr server is running (`herdr server`), then open rai.

Prefer to build it yourself? `git clone` and run `./scripts/bundle.sh`.
