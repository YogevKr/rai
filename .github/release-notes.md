Native macOS client for [herdr](https://herdr.dev). Universal binary (Apple Silicon + Intel), macOS 14+.

### New in this release

- **The Codex Micro mic key dictates again.** Wispr Flow's event tap ignores
  synthetic keyboard events, so the old approach — synthesizing Wispr's
  push-to-talk chord while the mic key is held — silently stopped working.
  The mic key now drives Wispr through its own deep links instead:
  `start-hands-free` on press, `stop-hands-free` on release. Hold the key,
  speak, release; the transcript lands in the focused pane. No Accessibility
  permission needed for this anymore.

### Install

```sh
brew install --cask yogevkr/tap/rai
```

Or download the `.dmg` below, open it, and drag **Rai** into **Applications**.

Then open rai — it starts the herdr server itself if one is not running.

Prefer to build it yourself? `git clone` and run `./scripts/bundle.sh`.
