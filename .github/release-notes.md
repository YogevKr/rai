Native macOS client for [herdr](https://herdr.dev). Universal binary (Apple Silicon + Intel), macOS 14+.

### New in this release

- **Faster Mac typing during heavy terminal output.** Rai parses output in
  bounded chunks and gives keyboard events time between chunks. The terminal
  reader limits pending output while keyboard input uses a separate path.
- **Complete iPhone terminal history during live output.** Rai Remote refreshes
  history from the Mac while preserving the screen, cursor, colors, and scroll
  position. Repeated rows remain visible without leaving and reopening the pane.

The companion update is **Rai Remote build 35** on TestFlight.
Update both apps for the complete terminal history fix.

Bridge protocol stays 6 (all additions are optional fields); existing
pairings keep working.

### Install

```sh
brew install --cask yogevkr/tap/rai
```

Or download the `.dmg` below, open it, and drag **Rai** into **Applications**.

Then open rai — it starts the herdr server itself if one is not running.

Prefer to build it yourself? `git clone` and run `./scripts/bundle.sh`.
