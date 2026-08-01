Native macOS client for [herdr](https://herdr.dev). Universal binary (Apple Silicon + Intel), macOS 14+.

### Fixed in this release

- **Opening a pane no longer renders its output twice.** The terminal attached
  at SwiftTerm's default 80×25 before the pane had been laid out, so herdr drew
  the pane at 80 columns and the real width landed about 100ms later — and every
  agent TUI that reprints on resize left an 80-column copy of its output in the
  scrollback above the reflowed one. The attach now waits for the pane's real
  size, so herdr renders it once.

### Install

```sh
brew install --cask yogevkr/tap/rai
```

Or download the `.dmg` below, open it, and drag **Rai** into **Applications**.

Then open rai — it starts the herdr server itself if one is not running.

Prefer to build it yourself? `git clone` and run `./scripts/bundle.sh`.
