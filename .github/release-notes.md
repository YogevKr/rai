Native macOS client for [herdr](https://herdr.dev). Universal binary (Apple Silicon + Intel), macOS 14+.

### New in this release

- **Drop an image onto a Claude pane and it attaches as `[Image #N]`** —
  instantly, exactly like pasting a screenshot (the image also lands on your
  clipboard). Non-image files drop as shell-escaped paths with proper paste
  semantics.
- **Copying terminal text no longer drags row padding along.** Copied lines
  used to carry a full pty width of trailing spaces, so pasting into anything
  that wraps produced a blank row under every line.
- **Phone pane streams mirror the pane's native size and heal themselves.**
  The companion sees the whole pane (all columns and rows, scrollable), a
  stream that dies restarts on its own instead of freezing the phone on stale
  content, and the viewport follows the cursor.

### Install

1. Download the `.dmg` below, open it, and drag **Rai** into **Applications**.
2. rai isn't notarized yet (no paid Apple Developer account), so on first launch
   macOS Gatekeeper will block it. Do **one** of:
   - **Right-click** `Rai.app` → **Open** → **Open**, or
   - run `xattr -dr com.apple.quarantine /Applications/Rai.app` and launch normally.
3. Make sure a herdr server is running (`herdr server`), then open rai.

Prefer to build it yourself? `git clone` and run `./scripts/bundle.sh`.
