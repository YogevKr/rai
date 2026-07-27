Native macOS client for [herdr](https://herdr.dev). Universal binary (Apple Silicon + Intel), macOS 14+.

### New in this release

- **Selection auto-scroll at both edges** — drag a selection to the top *or*
  bottom edge of a terminal and the viewport now scrolls while the selection
  keeps growing, so you can select past what's on screen. Previously the bottom
  edge never scrolled (and the top was inconsistent).
- **The wheel keeps your selection** — scrolling while text is selected now
  moves the terminal's own scrollback so the highlight stays glued to its text,
  instead of the running program scrolling out from under the selection.

### Install

1. Download the `.dmg` below, open it, and drag **Rai** into **Applications**.
2. rai isn't notarized yet (no paid Apple Developer account), so on first launch
   macOS Gatekeeper will block it. Do **one** of:
   - **Right-click** `Rai.app` → **Open** → **Open**, or
   - run `xattr -dr com.apple.quarantine /Applications/Rai.app` and launch normally.
3. Make sure a herdr server is running (`herdr server`), then open rai.

Prefer to build it yourself? `git clone` and run `./scripts/bundle.sh`.
