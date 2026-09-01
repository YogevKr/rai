Native macOS client for [herdr](https://herdr.dev). Universal binary (Apple Silicon + Intel), macOS 14+.

### Fixed in this release

- **Tab titles on the phone no longer show a bare number.** herdr auto-names
  a fresh tab after its own number ("3") until it gets a real title. The Mac
  already knew to treat that as no title and fall back to the pane's terminal
  title; the phone didn't, so an auto-named tab showed the literal digit
  instead of the running agent's task. Both platforms now fall back the same
  way.

### Install

```sh
brew install --cask yogevkr/tap/rai
```

Or download the `.dmg` below, open it, and drag **Rai** into **Applications**.

Then open rai — it starts the herdr server itself if one is not running.

Prefer to build it yourself? `git clone` and run `./scripts/bundle.sh`.
