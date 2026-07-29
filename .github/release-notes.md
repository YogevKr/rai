Native macOS client for [herdr](https://herdr.dev). Universal binary (Apple Silicon + Intel), macOS 14+.

### New in this release

- **Drop a file onto a pane to type its path.** Drag a file from Finder onto
  any terminal pane (Ghostty parity): the pane is focused and the
  shell-escaped path is typed into its pty — ready for Claude's input or any
  shell prompt. Works alongside pane-swap dragging.
- **The phone now mirrors a pane's full grid.** Streams are never smaller
  than the pane, so on the phone the live prompt stays visible with the
  keyboard up, output follows the bottom, and you can scroll the whole pane.
  (Companion app fixes ship in TestFlight build 21; older phone builds keep
  working unchanged.)
- **App icon badge on the phone is a real count.** Pushes delivered since the
  phone last connected set the badge; opening the app clears it — no more
  stale "1" stuck on the icon.

### Install

1. Download the `.dmg` below, open it, and drag **Rai** into **Applications**.
2. rai isn't notarized yet (no paid Apple Developer account), so on first launch
   macOS Gatekeeper will block it. Do **one** of:
   - **Right-click** `Rai.app` → **Open** → **Open**, or
   - run `xattr -dr com.apple.quarantine /Applications/Rai.app` and launch normally.
3. Make sure a herdr server is running (`herdr server`), then open rai.

Prefer to build it yourself? `git clone` and run `./scripts/bundle.sh`.
