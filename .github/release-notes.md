Native macOS client for [herdr](https://herdr.dev). Universal binary (Apple Silicon + Intel), macOS 14+.

### New in this release

- **Typing stays responsive in large herds.** Working status dots no longer
  run continuous animations. This change stops constant UI redraws and reduces
  idle CPU use.

### Install

```sh
brew install --cask yogevkr/tap/rai
```

Or download the `.dmg` below, open it, and drag **Rai** into **Applications**.

Then open rai — it starts the herdr server itself if one is not running.

Prefer to build it yourself? `git clone` and run `./scripts/bundle.sh`.
