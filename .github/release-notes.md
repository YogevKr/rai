Native macOS client for [herdr](https://herdr.dev). Universal binary (Apple Silicon + Intel), macOS 14+.

### New in this release

- **Tab labels no longer show spinner circles either.** v0.1.38 stripped
  Claude Code's half-circle spinner glyphs (◐ ◓ ◑ ◒) from pane titles, but
  herdr also freezes the glyph into auto-generated tab labels. Those labels
  now get the same treatment.

### Install

```sh
brew install --cask yogevkr/tap/rai
```

Or download the `.dmg` below, open it, and drag **Rai** into **Applications**.

Then open rai — it starts the herdr server itself if one is not running.

Prefer to build it yourself? `git clone` and run `./scripts/bundle.sh`.
