Native macOS client for [herdr](https://herdr.dev). Universal binary (Apple Silicon + Intel), macOS 14+.

### New in this release

- **Pane titles no longer show spinner circles.** Claude Code 2.1.228 changed
  its terminal-title busy spinner to half-circle glyphs (◐ ◓ ◑ ◒) that herdr
  does not strip yet. rai now strips agent status glyphs itself when it
  decodes titles. This also stops sidebar rows from redrawing on every
  spinner frame.

### Install

```sh
brew install --cask yogevkr/tap/rai
```

Or download the `.dmg` below, open it, and drag **Rai** into **Applications**.

Then open rai — it starts the herdr server itself if one is not running.

Prefer to build it yourself? `git clone` and run `./scripts/bundle.sh`.
