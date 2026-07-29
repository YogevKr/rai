Native macOS client for [herdr](https://herdr.dev). Universal binary (Apple Silicon + Intel), macOS 14+.

### New in this release

- **Drag a split pane into the sidebar to make it a tab.** Drop it on a tab row
  to place it before that tab. Drop it on a space header to append it there.
  rai keeps the pane title and selects the new tab.

### Install

```sh
brew install --cask yogevkr/tap/rai
```

Or download the `.dmg` below, open it, and drag **Rai** into **Applications**.

Then make sure a herdr server is running (`herdr server`), and open rai.

Prefer to build it yourself? `git clone` and run `./scripts/bundle.sh`.
